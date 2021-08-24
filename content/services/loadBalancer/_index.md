---
title: "LoadBalancer"
date: 2020-09-13T17:33:04+01:00
weight: 70
---

LoadBalancer is the most common way of exposing backend applications to the outside world. Its API is very similar to [NodePort](/services/nodeport/) with the only exception being the `spec.type: LoadBalancer`. At the very least, a user is expected to define which ports to expose and a label selector to match backend Pods:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  ports:
  - name: web
    port: 80
  selector:
    app: web
  type: LoadBalancer
```

From the networking point of view, a LoadBalancer Service is expected to accomplish three things:

* Allocate a new, externally routable IP from a pool of addresses and release it when a Service is deleted.
* Make sure the packets for this IP get delivered to one of the Kubernetes Nodes.
* Program Node-local data plane to deliver the incoming traffic to one of the healthy backend Endpoints.

By default, Kubernetes will only take care of the last item, i.e. `kube-proxy` (or it's equivalent) will program a Node-local data plane to enable external reachability -- most of the work to enable this is already done by the [NodePort](/services/nodeport/) implementation. However, the most challenging part -- IP allocation and reachability -- is left for external implementations. What this means is that in a vanilla Kubernetes cluster, LoadBalancer Services will remain in a "pending" state, i.e. they will have no external IP and will not be reachable from the outside:

```bash
$ kubectl get svc web
NAME   TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)        AGE
web    LoadBalancer   10.96.86.198   <pending>     80:30956/TCP   43s
```

However, as soon as a LoadBalancer controller gets installed, it collects all "pending" Services and allocates a unique external IP from its own pool of addresses. It then updates a Service status with the allocated IP and configures external infrastructure to deliver incoming packets to (by default) all Kubernetes Nodes.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
  namespace: default
spec:
  clusterIP: 10.96.174.4
  ports:
  - name: web
    nodePort: 32634
    port: 80
  selector:
    app: web
  type: LoadBalancer
status:
  loadBalancer:
    ingress:
    - ip: 198.51.100.0
```

As anything involving orchestration of external infrastructure, the mode of operation of a LoadBalancer controller depends on its environment:

* Both on-prem and public **cloud-based clusters** can use existing cloud L4 load-balancers, e.g. [Network Load Balancer](https://docs.aws.amazon.com/eks/latest/userguide/network-load-balancing.html) (NLB) for Amazon Elastic Kubernetes Service (EKS), [Standard Load Balancer](https://docs.microsoft.com/en-us/azure/aks/load-balancer-standard) for Azure Kubernetes Services (AKE), [Cloud Load Balancer](https://cloud.google.com/load-balancing/docs/network) for Google Kubernetes Engine (GKE), [LBaaS plugin](https://docs.openstack.org/kuryr-kubernetes/latest/installation/services.html) for Openstack or [NSX ALB](https://docs.vmware.com/en/VMware-Tanzu/services/tanzu-adv-deploy-config/GUID-avi-ako-tkg.html) for VMWare.
The in-cluster components responsible for load-balancer orchestration is called [`cloud-controller-manager`](https://kubernetes.io/docs/concepts/architecture/cloud-controller/) and is usually deployed next to the `kube-controller-manager` as a part of the Kubernetes control plane.

* **On-prem clusters** can have multiple configurations options, depending on the requirements and what infrastructure may already be available in a data centre: 
  * Existing **load-balancer appliances** from incumbent vendors like F5 can be [integrated](https://cloud.google.com/architecture/partners/installing-f5-big-ip-adc-for-gke-on-prem?hl=en) with on-prem clusters allowing for the same appliance instance to be re-used for multiple purposes.
  * If direct interaction with the physical network is possible, load-balancing can be performed by one of the many **cluster add-ons**, utilising either gratuitous ARP (for L2 integration) or BGP (for L3 integration) protocols to advertise external IPs and attract traffic for those IPs to cluster Nodes.


There are many implementations of these cluster add-ons ranging from simple controllers, designed to work in isolated environments, all the way to feature-rich and production-grade projects. This is a relatively active area of development with new [projects](https://landscape.cncf.io/card-mode?category=service-proxy) appearing almost every year. The table below is an attempt to summarise some of the currently available solutions along with their notable features:

| Name | Description | 
| ---- | ----------  |
| [MetalLB](https://metallb.universe.tf/) | One of the most mature projects today. Supports both ARP and BGP modes via custom userspace implementations. Currently can only be configured via ConfigMaps with [CRD-based operator](https://github.com/metallb/metallb-operator) in the works. |
| [OpenELB](https://github.com/kubesphere/openelb) | Developed as a part of a wider project called [Kubesphere](https://www.cncf.io/wp-content/uploads/2020/12/KubeSphere-chinese-webinar.pdf). Supports both ARP and BGP modes, with BGP implementation built on top of GoBGP. Configured via CRDs. | 
| [Kube-vip](https://kube-vip.io/) | Started as a solution for Kubernetes control plane high availability and got extended to function as a LoadBalancer controller. Supports both L2 and GoBGP-based L3 modes. Can be configured via flags, env vars and ConfigMaps. |
|  [PureLB](https://gitlab.com/purelb/purelb) | Fork of metalLB with reworked ARP and BGP implementations. Uses BIRD for BGP and can be configured via CRDs. | 
| [Klipper](https://rancher.com/docs/k3s/latest/en/networking/#service-load-balancer) | An integrated LB controller for K3S clusters. Exposes LoadBalancer Services as [hostPorts](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#support-hostport) on all cluster Nodes. |
| [Akrobateo](https://github.com/kontena/akrobateo) | Extends the idea borrowed from klipper to work on any general-purpose Kubernetes Node (not just K3S). Like klipper, it doesn't use any extra protocol and simply relies on the fact that Node IPs are reachable from the rest of the network. The project is [no longer active](https://web.archive.org/web/20200107111252/https://blog.kontena.io/farewell/). |

Each of the above projects has its own pros and cons but I deliberately didn't want to make a decision matrix. Instead, I'll provide a list of things worth considering when choosing a LoadBalancer add-on:

* **IPv6 support** -- despite IPv6-only and dual-stack networking being supported for internal Kubernetes addressing, IPv6 support for external IPs is still quite patchy among many of the projects.
* **Community** -- this applies to most of the CNCF projects, having an active community is a sign of a healthy project that is useful to more than just its main contributors.
* **Control plane HA LB** -- this is very often left out of scope, however, it is still a problem that needs to be solved, especially for external access.
* **Proprietary vs existing routing implementation** -- although the former may be an easier implementation choice (we only need a small subset of ARP and BGP protocols), troubleshooting may become an issue if the control plane is abstracted away and extending its functionality is a lot more challenging compared to just turning on a knob in one of the existing routing daemons.
* **CRD vs ConfigMap** -- CRDs provide an easier and Kubernetes-friendly way of configuring in-cluster resources.


Finally, it's very important to understand why LoadBalancer Services are also assigned with a unique NodePort ([previous chapter](/services/nodeport/) explains how it happens). As we'll see in the below [lab scenarios](/services/loadbalancer/#lab), NodePort is not really needed if we use direct network integration via BGP or ARP. In these cases, the underlying physical network is aware of both the external IP, as learned from BGP's NLRI or ARP's SIP/DIP fields, and its next-hop learned from BGP's next-hop or ARP's source MAC fields. This information is advertised throughout the network so that every device knows where to send these packets. 

However, the same does not apply to environments where L4 load-balancer is located multiple hops away from cluster Nodes. In these cases, intermediate network devices are not aware of external IPs and only know how to forward packets to Node IPs. This is why an external load-balancer will DNAT incoming packets to one of the Node IPs and will use NodePort as a unique identifier of a target Service.

The last point is summarised in the following high-level diagram, showing how load-balancers operate in two different scenarios:


{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=xeDI84nk2ZPcPtgblqcf&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Lab

The lab will demonstrate how MetalLB operates in an L3 mode. We'll start with a control plane (BGP) overview and demonstrate three different modes of data plane operation:

* **IPTables** orchestrated by kube-proxy
* **IPVS** orchestrated by kube-proxy
* **eBPF** orchestrated by Cilium


### Preparation

Refer to the respective chapters for the instructions on how to setup [IPTables](/services/clusterip/dataplane/iptables/#lab-setup), [IPVS](/services/clusterip/dataplane/ipvs/#lab-setup) or [eBPF](/services/clusterip/dataplane/ebpf/#preparation) data planes.  Once the required data plane is configured, setup a test deployment with 3 Pods and expose it via a LoadBalancer Service:

```
$ make deployment && make scale-up && make loadbalancer
kubectl create deployment web --image=nginx
deployment.apps/web created
kubectl scale --replicas=3 deployment/web
deployment.apps/web scaled
kubectl expose deployment web --port=80 --type=LoadBalancer
service/web exposed
```

The above command will also deploy a standalone container called `frr`. This container is attached to the same bridge as the lab Nodes and runs a BGP routing daemon (as a part of [FRR](http://docs.frrouting.org/en/latest/)) that will act as a top of the rack (TOR) switch in a physical data centre. It is [pre-configured](https://github.com/networkop/k8s-guide-labs/blob/master/frr/frr.conf) to listen for incoming BGP connection requests, will automatically peer with them and install any received routes into its local routing table.

Confirm the assigned LoadBalancer IP, e.g. `198.51.100.0` in the output below:

```
$ kubectl get svc web
NAME         TYPE           CLUSTER-IP     EXTERNAL-IP    PORT(S)        AGE
web          LoadBalancer   10.96.86.198   198.51.100.0   80:30956/TCP   2d23h
```

To verify that the LoadBalancer Service is functioning, try connecting to the deployment from a virtual TOR container running the BGP daemon:

```
docker exec frr wget -q -O - 198.51.100.0 | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
```

Finally, setup the following command aliases:

```bash
NODE=k8s-guide-worker2
alias ipt="docker exec $NODE iptables -t nat -nvL"
alias ipv="docker exec $NODE ipvsadm -ln"
alias ips="docker exec $NODE ipset list"
alias cilium="kubectl -n cilium exec $(kubectl get -l k8s-app=cilium pods -n cilium --field-selector spec.nodeName=$NODE -o jsonpath='{.items[0].
metadata.name}') --"
alias frr="docker exec frr"
```

### Control plane overview


First, let's check how the routing table looks inside of our virtual TOR switch:
```bash
$ frr ip route show 198.51.100.0
198.51.100.0 nhid 37 proto bgp metric 20
        next-hop via 192.168.224.4 dev eth0 weight 1
        next-hop via 192.168.224.6 dev eth0 weight 1
        next-hop via 192.168.224.5 dev eth0 weight 1
```


We see a single host route with three equal-cost next-hops. This route is the result of BGP updates received from three MetalLB speakers: 

```
$ frr vtysh -c 'show ip bgp sum'

IPv4 Unicast Summary:
BGP router identifier 198.51.100.255, local AS number 64496 vrf-id 0
BGP table version 5
RIB entries 1, using 192 bytes of memory
Peers 3, using 43 KiB of memory
Peer groups 1, using 64 bytes of memory

Neighbor        V         AS   MsgRcvd   MsgSent   TblVer  InQ OutQ  Up/Down State/PfxRcd   PfxSnt
*192.168.224.4  4      64500       297       297        0    0    0 02:27:29            1        1
*192.168.224.5  4      64500       297       297        0    0    0 02:27:29            1        1
*192.168.224.6  4      64500       297       297        0    0    0 02:27:29            1        1
```

Let's see how these updates look inside of the BGP database:

```
frr vtysh -c 'show ip bgp'
BGP table version is 5, local router ID is 198.51.100.255, vrf id 0
Default local pref 100, local AS 64496
Status codes:  s suppressed, d damped, h history, * valid, > best, = multipath,
               i internal, r RIB-failure, S Stale, R Removed
next-hop codes: @NNN next-hop's vrf id, < announce-nh-self
Origin codes:  i - IGP, e - EGP, ? - incomplete

   Network          next-hop            Metric LocPrf Weight Path
*> 198.51.100.0/32  192.168.224.4                          0 64500 ?
*=                  192.168.224.5                          0 64500 ?
*=                  192.168.224.6                          0 64500 ?

Displayed  1 routes and 3 total paths
```

Unlike standard BGP daemons, MetalLB BGP speakers do not accept any incoming updates, so there's no way to influence the outbound routing. However, just sending out the updates out while setting the next-hop to `self` is enough to establish external reachability. In a normal network, these updates will propagate throughout the fabric and within seconds the entire data centre will be aware of the new IP and where to forward it.

{{% notice note %}}
Since MetalLB implements both L2 and L3 modes in custom userspace code and doesn't interact with the kernel FIB, there's very limited visibility into the control plane state of the speakers -- they will only log certain life-cycle events (e.g. BGP session state) which can be viewed with `kubectl logs`.
{{% /notice %}}

### IPTables data plane

As soon a LoadBalancer controller publishes an external IP in the `status.loadBalancer` field, `kube-proxy`, who watches all Services, gets notified and inserts the `KUBE-FW-*` chain right next to the `ClusterIP` entry of the same Service. So somewhere inside the `KUBE-SERVICES` chain, you will see a rule that matches the external IP:

```bash
$ ipt KUBE-SERVICES
...
    0     0 KUBE-SVC-LOLE4ISW44XBNF3G  tcp  --  *      *       0.0.0.0/0            10.96.86.198         /* default/web cluster IP */ tcp dpt:80
    5   300 KUBE-FW-LOLE4ISW44XBNF3G  tcp  --  *      *       0.0.0.0/0            198.51.100.0         /* default/web loadbalancer IP */ tcp dpt:80
...
```

Inside the `KUBE-FW` chain packets get marked for IP masquerading (SNAT to incoming interface) and get redirected to the `KUBE-SVC-*` chain. The last `KUBE-MARK-DROP` entry is used when `spec.loadBalancerSourceRanges` are defined in order to drop packets from unspecified prefixes:

{{< highlight bash "linenos=false,hl_lines=5" >}}
$ ipt KUBE-FW-LOLE4ISW44XBNF3G
Chain KUBE-FW-LOLE4ISW44XBNF3G (1 references)
 pkts bytes target     prot opt in     out     source               destination
    5   300 KUBE-MARK-MASQ  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web loadbalancer IP */
    5   300 KUBE-SVC-LOLE4ISW44XBNF3G  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web loadbalancer IP */
    0     0 KUBE-MARK-DROP  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web loadbalancer IP */
{{< / highlight >}}

The `KUBE-SVC` chain is the same as the one used for the ClusterIP Services -- one of the Endpoints gets chosen randomly and incoming packets get DNAT'ed to its address inside one of the `KUBE-SEP-*` chains:

```
$ ipt KUBE-SVC-LOLE4ISW44XBNF3G
Chain KUBE-SVC-LOLE4ISW44XBNF3G (3 references)
 pkts bytes target     prot opt in     out     source               destination
    1    60 KUBE-SEP-PJHHG4YJTBHVHUTY  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ statistic mode random probability 0.33333333349
    3   180 KUBE-SEP-ZA2JI7K7LSQNKDOS  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */ statistic mode random probability 0.50000000000
    1    60 KUBE-SEP-YUPMFTK3IHSQP2LT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* default/web */
```

See [IPTables chapter](http://localhost:1313/services/clusterip/dataplane/iptables/#use-case-1-pod-to-service-communication) for more details.

### IPVS data plane

LoadBalancer IPVS implementation is very similar to [NodePort](/services/nodeport/). The first rule of the `KUBE-SERVICES` chain intercepts all packets with a matching destination IP:
{{< highlight bash "linenos=false,hl_lines=4" >}}
$ ipt KUBE-SERVICES
Chain KUBE-SERVICES (2 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-LOAD-BALANCER  all  --  *      *       0.0.0.0/0            0.0.0.0/0            /* Kubernetes service lb portal */ match-set KUBE-LOAD-BALANCER dst,dst
    0     0 KUBE-MARK-MASQ  all  --  *      *      !10.244.0.0/16        0.0.0.0/0            /* Kubernetes service cluster ip + port for masquerade purpose */ match-set KUBE-CLUSTER-IP dst,dst
    4   240 KUBE-NODE-PORT  all  --  *      *       0.0.0.0/0            0.0.0.0/0            ADDRTYPE match dst-type LOCAL
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-CLUSTER-IP dst,dst
    0     0 ACCEPT     all  --  *      *       0.0.0.0/0            0.0.0.0/0            match-set KUBE-LOAD-BALANCER dst,dst
{{< / highlight >}}

The `KUBE-LOAD-BALANCER` ipset contains all external IPs allocated to LoadBalancer Services:

```
$ ips KUBE-LOAD-BALANCER
Name: KUBE-LOAD-BALANCER
Type: hash:ip,port
Revision: 5
Header: family inet hashsize 1024 maxelem 65536
Size in memory: 256
References: 2
Number of entries: 1
Members:
198.51.100.0,tcp:80
```

All matched packets get marked for SNAT, which is explained in more detail in the [IPTables chapter](http://localhost:1313/services/clusterip/dataplane/iptables/#use-case-2-any-to-service-communication):

```
$ ipt KUBE-LOAD-BALANCER
Chain KUBE-LOAD-BALANCER (1 references)
 pkts bytes target     prot opt in     out     source               destination
    0     0 KUBE-MARK-MASQ  all  --  *      *       0.0.0.0/0            0.0.0.0/0
```  

The IPVS configuration contains one entry per external IP with all healthy backend Endpoints selected in a round-robin fashion:

```
$ ipv
IP Virtual Server version 1.2.1 (size=4096)
Prot LocalAddress:Port Scheduler Flags
  -> RemoteAddress:Port           Forward Weight ActiveConn InActConn
...
TCP  198.51.100.0:80 rr
  -> 10.244.1.6:80                Masq    1      0          0
  -> 10.244.2.5:80                Masq    1      0          0
  -> 10.244.2.6:80                Masq    1      0          0
...
```

### Cilium eBPF data plane

Cilium treats LoadBalancer Services the same way as NodePort. All of the code walkthroughs from the [eBPF section](http://localhost:1313/services/nodeport/#cilium-ebpf-implementation) of the NodePort Chapter will apply to this use case, i.e. incoming packets get intercepted as they ingress one of the external interfaces and get matched against a list of configured Services:

```
$ cilium bpftool map dump pinned /sys/fs/bpf/tc/globals/cilium_lb4_services_v2 | grep c6
key: c6 33 64 00 00 50 01 00  00 00 00 00  value: 07 00 00 00 00 00 00 08  00 00 00 00
key: c6 33 64 00 00 50 00 00  00 00 00 00  value: 00 00 00 00 03 00 00 08  60 00 00 00
key: c6 33 64 00 00 50 03 00  00 00 00 00  value: 09 00 00 00 00 00 00 08  00 00 00 00
key: c6 33 64 00 00 50 02 00  00 00 00 00  value: 08 00 00 00 00 00 00 08  00 00 00 00
```

If a match is found, packets go through destination NAT and optionally source address translation (for Services with `spec.externalTrafficPolicy` set to `Cluster`) and get redirected straight to the Pod's veth interface. See the [NodePort chapter](http://localhost:1313/services/nodeport/#cilium-ebpf-implementation) for more details and code overview.


### Caveats

* For a very long time, Kubernetes only supported a single LoadBalancer Controller. Running multiple controllers has been introduced in a [recent feature](https://github.com/kubernetes/enhancements/tree/master/keps/sig-cloud-provider/1959-service-lb-class-field), however controller implementations are still [catching up](https://github.com/metallb/metallb/issues/685).

* Most of the big public cloud providers do not support the BYO controller model, so cluster add-ons that rely on L2 or L3 integration would only work in some clouds (e.g. Packet) but not in others (e.g. AWS, Azure, GCP). However, it's still [possible](https://maelvls.dev/avoid-gke-lb-with-hostport/) to use controllers that use hostPort (e.g. klipper, akrobateo).