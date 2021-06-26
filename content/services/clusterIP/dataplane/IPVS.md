---
title: "IPVS"
date: 2020-09-13T17:33:04+01:00
weight: 20
---


https://www.projectcalico.org/comparing-kube-proxy-modes-iptables-or-ipvs/

https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/

https://github.com/kubernetes/enhancements/tree/0e4d5df19d396511fe41ed0860b0ab9b96f46a2d/keps/sig-network/265-ipvs-based-load-balancing

https://docs.google.com/presentation/d/1BaIAywY2qqeHtyGZtlyAp89JIZs59MZLKcFLxKE6LyM/edit

scheduler
https://kubernetes.io/blog/2018/07/09/ipvs-based-in-cluster-load-balancing-deep-dive/#parameter-changes


{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=BucKDkpFbDgBnzcmmJd5&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}



### Lab Setup

Assuming that the lab environment is already [set up](/lab/), ipvs can be enabled with the following commands:

```bash
make ipvs
```



{{< highlight bash "linenos=false" >}}
$ make kube-proxy-logs | grep IPVS
E0626 17:19:43.491383       1 server_others.go:127] Can't use the IPVS proxier: IPVS proxier will not be used because the following required kernel modules are not loaded: [ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh]
{{< / highlight >}}

Under the covers, the above command updates the proxier mode in `kube-proxy`'s ConfigMap so in order for this change to get picked up, we need to restart all of the agents and flush out any existing iptable rules:

```bash
make flush-nat
```

A good way to verify that the change has suceeded is to check that all Nodes now have a dummy ipvs device and a much smaller set of NAT rules:

{{< highlight bash "linenos=false,hl_lines=2 6" >}}
$ docker exec -it k8s-guide-worker ip link show kube-ipvs0 
7: kube-ipvs0: <BROADCAST,NOARP> mtu 1500 qdisc noop state DOWN mode DEFAULT group default
    link/ether 22:76:01:f0:71:9f brd ff:ff:ff:ff:ff:ff

$ docker exec -it k8s-guide-worker iptables -t nat -nvL KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
{{< / highlight >}}


{{% notice note %}}
One thing to remember when migrating from iptables to ipvs on an existing cluster (as opposed to rebuilding it from scratch), is that all of the KUBE-SVC/KUBE-SEP chains will still be there and may need to be cleaned up either manually or with a Node reboot.
{{% /notice %}}

Spin up a test deployment and expose it as `ClusterIP` type service:


```bash
kubectl create deploy web --image=nginx --replicas=2
kubectl expose deploy web --port 80
```

Check that all Pods are up and what IP got assigned to our service:

{{< highlight bash "linenos=false,hl_lines=3-4 7" >}}
$ kubectl get pod -owide -l app=web
NAME                  READY   STATUS    RESTARTS   AGE    IP           NODE                NOMINATED NODE   READINESS GATES
web-96d5df5c8-6bgpr   1/1     Running   0          111s   10.244.1.6   k8s-guide-worker    <none>           <none>
web-96d5df5c8-wkfrb   1/1     Running   0          111s   10.244.2.4   k8s-guide-worker2   <none>           <none>
$ kubectl get svc web
NAME   TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)   AGE
web    ClusterIP   10.96.119.228   <none>        80/TCP    92s
{{< / highlight >}}

Before we move forward, there are a couple of dependencies we need to satisfy. First, pick one of the Nodes hosting our test deployment and install the following packages:

```bash
docker exec k8s-guide-worker apt update 
docker exec k8s-guide-worker apt install ipset ipvsadm -y
```

Finally, one the same Node set up the following set of aliases for iptables, ipvs and ipset:

```bash
alias ipt="docker exec k8s-guide-worker iptables -t nat -nvL"
alias ipv="docker exec k8s-guide-worker ipvsadm -ln"
alias ips="docker exec k8s-guide-worker ipset list"
```

### Use case #1: Pod-to-Service communication

{{< highlight bash "linenos=false,hl_lines=3-4 7" >}}
$  ipt PREROUTING
Chain PREROUTING (policy ACCEPT 0 packets, 0 bytes)
 pkts bytes target     prot opt in     out     source               destination
  128 12020 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
    0     0 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
{{< / highlight >}}

{{< highlight bash "linenos=false,hl_lines=6" >}}
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
{{< / highlight >}}


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


### Use case #2: Any-to-Service communication

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt OUTPUT
Chain OUTPUT (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1062 68221 KUBE-SERVICES  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service portals */
  287 19636 DOCKER_OUTPUT  all  --  *      *       0.0.0.0/0            192.168.224.1
{{< / highlight >}}

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    0     0 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
{{< / highlight >}}

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt KUBE-MARK-MASQ
Chain KUBE-MARK-MASQ (13 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK or 0x4000
{{< / highlight >}}

{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt POSTROUTING
Chain POSTROUTING (policy ACCEPT 5 packets, 300 bytes)
 pkts bytes target     prot opt in     out     source               destination
 1199 80799 KUBE-POSTROUTING  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes postrouting rules */
    0     0 DOCKER_POSTROUTING  all  --  *      *       0.0.0.0/0            192.168.224.1
  920 61751 KIND-MASQ-AGENT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type !LOCAL /* kind-masq-agent: ensure nat POSTROUTING directs all non-LOCAL destination traffic to our custom KIND-MASQ-AGENT chain */
{{< / highlight >}}

{{< highlight bash "linenos=false,hl_lines=4 " >}}
$ ipt KUBE-POSTROUTING
Chain KUBE-POSTROUTING (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes endpoints dst ip:port, source ip for solving hairpin purpose */ match-set KUBE-LOOP-BACK dst,dst,src
    1    60 RETURN     all  --  *      *       0.0.0.0/0            0.0.0.0/0            mark match ! 0x4000/0x4000
    0     0 MARK       all  --  *      *       0.0.0.0/0            0.0.0.0/0            MARK xor 0x4000
    0     0 MASQUERADE  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* kubernetes service traffic requiring SNAT */ random-fully
{{< / highlight >}}

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