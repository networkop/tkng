---
title: "IPVS"
date: 2020-09-13T17:33:04+01:00
weight: 20
---

IPTables has been the first implementation of kube-proxy's dataplane, however, overtime its limitations have become more pronounced, especially when operating at scale. There are several side-effects of implementing a proxy with something that was designed to be a firewall, the main one being being a limited set of data structures. The way it manifests itself is that every ClusterIP Service needs to have a unique entry, these entries can't be grouped and have to be processed sequentially as chains of tables. This means that any dataplane lookup or a create/update/delete operation needs to traverse the chain until a match is found which can result in [minutes](https://docs.google.com/presentation/d/1BaIAywY2qqeHtyGZtlyAp89JIZs59MZLKcFLxKE6LyM/edit#slide=id.p20) of added processing time. 

{{% notice note %}}
Detailed performance analysis and measurement results of running iptables at scale can be found in the [Additional Reading](#additional-reading) section at the bottom of the page.
{{% /notice %}}

All this led to `ipvs` being added as an [enhancement proposal](https://github.com/kubernetes/enhancements/tree/0e4d5df19d396511fe41ed0860b0ab9b96f46a2d/keps/sig-network/265-ipvs-based-load-balancing) and eventually graduating to GA in Kubernetes version 1.11. The new dataplane implementation offers a number of improvements over the existing `iptables` mode:

* All Service load-balancing is migrated to IPVS which can perform in-kernel lookups and masquerading in constant time, regardless of the number of configured Services or Endpoints.

* The remaining rules in IPTables have been re-engineered to make use of [ipset](https://wiki.archlinux.org/title/Ipset), making the lookups more effecient.

* Multiple additional load-balancer [scheduling modes](https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/#parameter-changes) are now available, with the default one being a simple round-robin.


On the surface, this makes the decision to use `ipvs` an obvious one, however, since `iptables` have been the default mode for so long, some of its quirks and undocumented side-effects have become the standard. One of the fortunate side-effects of the `iptables` mode is that `ClusterIP` is never bound to any kernel interface and remains completely virtual (as a NAT rule). So when  `ipvs` changed this behaviour by introducing a dummy `kube-ipvs0` interface, it [made it possible](https://github.com/kubernetes/kubernetes/issues/72236) for processes inside Pods to access any host-local services bound to `0.0.0.0` by targeting any existing `ClusterIP`. Although this does make `ipvs` less safe by default, it doesn't mean that these risks can't be mitigaged (e.g. by not binding to `0.0.0.0`).

The diagram below is a high-level and simplified view of two distinct datapaths for the same `ClusterIP` virtual service -- one from a remote Pod and one from a host-local interface.


{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=BucKDkpFbDgBnzcmmJd5&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}



### Lab Setup

Assuming that the lab environment is already [set up](/lab/), ipvs can be enabled with the following command:

```bash
make ipvs
```

Under the covers, the above command updates the proxier mode in kube-proxy's ConfigMap so in order for this change to get picked up, we need to restart all of the agents and flush out any existing iptable rules:

```bash
make flush-nat
```

Check the logs to make sure kube-proxy has loaded all of the [required kernel modules](https://github.com/kubernetes/kubernetes/blob/2f753ec4c826895e4ccd3d6bdda2b1ab777ceeb8/pkg/util/ipvs/ipvs.go#L130). In case of a failure, the following error will be present in the logs and kube-proxy will fall back to the `iptables` mode:


```bash
$ make kube-proxy-logs | grep -i ipvs
E0626 17:19:43.491383       1 server_others.go:127] Can't use the IPVS proxier: IPVS proxier will not be used because the following required kernel modules are not loaded: [ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh]
```

Another way to confirm that the change has suceeded is to check that Nodes now have a new dummy ipvs device:

{{< highlight bash "linenos=false,hl_lines=2" >}}
$ docker exec -it k8s-guide-worker ip link show kube-ipvs0 
7: kube-ipvs0: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN mode DEFAULT group default
    link/ether 22:76:01:f0:71:9f brd ff:ff:ff:ff:ff:ff promiscuity 0 minmtu 0 maxmtu 0
    dummy addrgenmode eui64 numtxqueues 1 numrxqueues 1 gso_max_size 65536 gso_max_segs 65535
{{< / highlight >}}


{{% notice note %}}
One thing to remember when migrating from iptables to ipvs on an existing cluster (as opposed to rebuilding it from scratch), is that all of the KUBE-SVC/KUBE-SEP chains will still be there at least until they cleaned up manually or a node is rebooted.
{{% /notice %}}

Spin up a test deployment and expose it as a `ClusterIP` Service:


```bash
kubectl create deploy web --image=nginx --replicas=2
kubectl expose deploy web --port 80
```

Check that all Pods are up and note the IP allocated to our Service:

{{< highlight bash "linenos=false,hl_lines=3-4 7" >}}
$ kubectl get pod -owide -l app=web
NAME                  READY   STATUS    RESTARTS   AGE    IP           NODE                NOMINATED NODE   READINESS GATES
web-96d5df5c8-6bgpr   1/1     Running   0          111s   10.244.1.6   k8s-guide-worker    <none>           <none>
web-96d5df5c8-wkfrb   1/1     Running   0          111s   10.244.2.4   k8s-guide-worker2   <none>           <none>
$ kubectl get svc web
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.119.228   <none>        80/TCP    92s
{{< / highlight >}}

Before we move forward, there are a couple of dependencies we need to satisfy: 

1.  Pick one of the Nodes hosting a test deployment and install the following packages:

```bash
docker exec k8s-guide-worker apt update 
docker exec k8s-guide-worker apt install ipset ipvsadm -y
```

2. On the same Node set up the following set of aliases to simplify access to iptables, ipvs and ipset:

```bash
alias ipt="docker exec k8s-guide-worker iptables -t nat -nvL"
alias ipv="docker exec k8s-guide-worker ipvsadm -ln"
alias ips="docker exec k8s-guide-worker ipset list"
```

### Use case #1: Pod-to-Service communication

Any packet leaving a Pod will first pass through the `PREROUTING` chain which is where kube-proxy intercepts all Service-bound traffic:

{{< highlight bash "linenos=false,hl_lines=3-4 7" >}}
$  ipt PREROUTING
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
  128 12020 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
    0     0 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
{{< / highlight >}}

The size of the `KUBE-SERVICES` chain is reduced compared to the [`iptables`](/services/clusterip/dataplane/iptables/) mode and the lookup stops once the destination IP is matched against the `KUBE-CLUSTER-IP` ipset:

{{< highlight bash "linenos=false,hl_lines=6" >}}
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
{{< / highlight >}}

This ipset contains all existing ClusterIPs and the lookup is performed in  [O(1)](https://en.wikipedia.org/wiki/Time_complexity#Constant_time) time:

{{< highlight bash "linenos=false,hl_lines=18" >}}
$ ips KUBE-CLUSTER-IP
Name: KUBE-CLUSTER-IP
Type: hash:ip,port
Revision: 5
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 768
References: 2
Number of entries: 9
Members:
10.96.0.10,udp:53
10.96.0.1,tcp:443
10.96.0.10,tcp:53
10.96.148.225,tcp:80
10.96.68.46,tcp:3030
10.96.10.207,tcp:3030
10.96.0.10,tcp:9153
10.96.159.35,tcp:11211
10.96.119.228,tcp:80
{{< / highlight >}}

Following the lookup in the `PREROUTING` chain, our packet gets to the [routing decision](https://upload.wikimedia.org/wikipedia/commons/3/37/Netfilter-packet-flow.svg) stage which is where it gets intercepted by  Netfilter's `NF_INET_LOCAL_IN` hook and redirected to IPVS. 



{{< highlight bash "linenos=false,hl_lines=20-22" >}}
$ ipv
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
TCP  192.168.224.4:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.0.1:443 rr
  -> 192.168.224.3:6443           Masq    1      0          0
TCP  10.96.0.10:53 rr
  -> 10.244.0.3:53                Masq    1      0          0
  -> 10.244.0.4:53                Masq    1      0          0
TCP  10.96.0.10:9153 rr
  -> 10.244.0.3:9153              Masq    1      0          0
  -> 10.244.0.4:9153              Masq    1      0          0
TCP  10.96.10.207:3030 rr
  -> 10.244.1.4:3030              Masq    1      0          0
TCP  10.96.68.46:3030 rr
  -> 10.244.2.2:3030              Masq    1      0          0
TCP  10.96.119.228:80 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.148.225:80 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  10.96.159.35:11211 rr
  -> 10.244.1.3:11211             Masq    1      0          0
TCP  10.244.2.1:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
TCP  127.0.0.1:31730 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.4:80                Masq    1      0          0
UDP  10.96.0.10:53 rr
  -> 10.244.0.3:53                Masq    1      0          8
  -> 10.244.0.4:53                Masq    1      0          8
{{< / highlight >}}


This is where the packet gets DNAT'ed to the IP of one of the selected backend Pods (`10.244.1.6` in our case) and continues on to its destination unmodified, following the forwarding path built by a CNI plugin.

### Use case #2: Any-to-Service communication

Any host-local service trying to communicate with a ClusterIP will first get its packet through `OUTPUT` and `KUBE-SERVICES` chains:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt OUTPUT
Chain OUTPUT (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1062 68221 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
  287 19636 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
{{< / highlight >}}

Since source IP does not belong to the PodCIDR range, our packet gets a de-tour via the `KUBE-MARK-MASQ` chain:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
{{< / highlight >}}

Here the packet gets marked for future SNAT, to make sure it will have a return path from the Pod:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt KUBE-MARK-MASQ
Chain KUBE-MARK-MASQ (13 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK or 0x4000
{{< / highlight >}}

The following few steps are exactly the same as described for the previous use case:

* The packet reaches the end of the `KUBE-SERVICES` chain.
* The routing lookup returns a local dummy ipvs interface.
* IPVS intercepts the packet and performs the backend selection and NATs the destination IP address.

The modified packet metadata continues along the forwarding path until it hits the egress `veth` interface where it gets picked up by the `POSTROUTING` chain:

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt POSTROUTING
Chain POSTROUTING (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1199 80799 KUBE-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes postrouting rules */
    0     0 DOCKER_POSTROUTING  all  --  *      *       0.0.0.0/0            192.168.224.1
  920 61751 KIND-MASQ-AGENT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type !LOCAL /* kind-masq-agent: ensure nat POSTROUTING directs all non-LOCAL destination traffic to our custom KIND-MASQ-AGENT chain */
{{< / highlight >}}

This is where the source IP of the packet gets modified to match the one of the egress interface, so the destination Pod knows where to send a reply:

{{< highlight bash "linenos=false,hl_lines=4 " >}}
$ ipt KUBE-POSTROUTING
Chain KUBE-POSTROUTING (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes endpoints dst ip:port, source ip for solving hairpin purpose */ match-set KUBE-LOOP-BACK dst,dst,src
    1    60 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            mark match ! 0x4000/0x4000
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK xor 0x4000
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service traffic requiring SNAT */ random-fully
{{< / highlight >}}

The final masquerading action is performed if the destination IP and Port matche one of the local Endpoints which are stored in the `KUBE-LOOP-BACK` ipset:

{{< highlight bash "linenos=false,hl_lines=11" >}}
$ ips KUBE-LOOP-BACK
Name: KUBE-LOOP-BACK
Type: hash:ip,port,ip
Revision: 5
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 360
References: 1
Number of entries: 2
Members:
10.244.1.2,tcp:3030,10.244.1.2
10.244.1.6,tcp:80,10.244.1.6
{{< / highlight >}}

{{% notice info %}}
It should be noted that, similar to the iptables mode, all of the above lookups are only performed for the first packet of the session and all subsequent packets follow a much shorter path in conntrack subsystem. 
{{% /notice %}}


### Additional reading

[Scaling Kubernetes to Support 50,000 Services](https://docs.google.com/presentation/d/1BaIAywY2qqeHtyGZtlyAp89JIZs59MZLKcFLxKE6LyM/edit#slide=id.p19)

[Comparing kube-proxy modes: iptables or IPVS?](https://www.projectcalico.org/comparing-kube-proxy-modes-iptables-or-ipvs/)

[IPVS-Based In-Cluster Load Balancing Deep Dive](https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/)