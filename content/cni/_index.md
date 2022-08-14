---
title: CNI
menuTitle: "CNI"
weight: 10
summary: Pod Networking within and between Nodes
---

## Main Goals

The official documentation [outlines](https://kubernetes.io/docs/concepts/cluster-administration/networking/#the-kubernetes-network-model) a number of requirements that any CNI plugin implementation should support. Rephrasing it in a slightly different way, a CNI plugin must provide at least the following two things:

* **Connectivity** - making sure that a Pod gets its default `eth0` interface with IP reachable from the root network namespace of the hosting Node.
* **Reachability** - making sure that Pods from other Nodes can reach each other directly (without NAT).

Connectivity requirement is the most straight-forward one to understand -- every Pod must have a NIC to communicate with anything outside of its own network namespace. Some local processes on the Node (e.g. kubelet) need to reach PodIP from the root network namespace (e.g. to perform health and readiness checks), hence the root NS connectivity requirement.

There are a number of [reference](https://github.com/containernetworking/plugins#main-interface-creating) CNI plugins that can be used to setup connectivity, most notable examples are:

* **ptp** -- creates a veth link in the root namespace and plugs the other end into the Pod's namespace.
* **bridge** -- does the same but also connects the rootNS end of the link to the bridge.
* **macvlan/ipvlan** -- use the corresponding drivers to connect containers directly to the NIC of the Node. 

{{% notice info %}}
These reference plugins are very often combined and re-used by other, more complicated CNI plugins (see [kindnet](/cni/kindnet/) or [flannel](/cni/flannel)).
{{% /notice %}}

Reachability, on the other hand, may require a bit of unpacking:

* Every Pod gets a unique IP from a `PodCIDR` range configured on the Node.
* This range is assigned to the Node during kubelet bootstrapping phase. 
* Nodes are not aware of `PodCIDRs` assigned to other Nodes, allocations are normally managed by the controller-manager based on the `--cluster-cidr` configuration flag.
* Depending on the type of underlying connectivity, establishing end-to-end reachability between `PodCIDRs` may require different methods:
    - If all Nodes are in the **same Layer2 domain**, the connectivity can be established by configuring a **full mesh of static routes** on all Nodes with NextHop set to the internal IP of the peer Nodes.
    - If some Nodes are in **different Layer2 domains**, the connectivity can be established with either:
        * **Orchestrating the underlay** -- usually done with BGP for on-prem or some form of dynamically-provisioned static routes for public cloud environments.
        * **Encapsulating in the overlay** -- VXLAN is still the most popular encap type.

{{% notice info %}}
The above mechanisms are not determined exclusively by the underlying network. Plugins can use a mixture of different methods (e.g. host-based static routes for the same L2 segment and overlays for anything else) and the choice can be made purely based on operational complexity (e.g. overlays over BGP).
{{% /notice %}}

{{% notice note %}}
It goes without saying that the base underlying assumption is that Nodes can reach each other using their Internal IPs. It is the responsibility of the infrastructure provider (IaaS) to fulfil this requirement.
{{% /notice %}}

## Secondary Goals

In addition to the base functionality described above, there's always a need to do things like:

* **IP address management** to keep track of IPs allocated to each individual Pod.
* **Port mappings** to expose Pods to the outside world.
* **Bandwidth control** to control egress/ingress traffic rates.
* **Source NAT** for traffic leaving the cluster (e.g. Internet)

These functions can be performed by the same monolithic plugin or via a **plugin chaining**, where multiple plugins are specified in the configuration file and get invoked sequentially by the container runtime. 


{{% notice info %}}
[CNI plugins repository](https://github.com/containernetworking/plugins) provides reference implementations of the most commonly used plugins.
{{% /notice %}}

## Operation

Contrary to the typical network plugin design approach that includes a long-lived stateful daemon, [CNI Specification](https://github.com/containernetworking/cni/blob/master/SPEC.md) defines an interface -- a set of input/output parameters that a CNI binary is expected to ingest/produce. This makes for a very clean design that is also very easy to swap and upgrade. The most beautiful thing is that the plugin becomes completely stateless -- it's just a binary file on a disk that gets invoked whenever a Pod gets created or deleted. Here's a sequence of steps that a container runtime has to do whenever a new Pod gets created:

1. It creates a new network namespace.
2. It reads and parses the CNI configuration file -- the (numerically) first file from `/etc/cni/net.d`
3. For every plugin specified in the configuration file, it invokes the corresponding binary, passing it the following information:
    * Environment variables `CNI_COMMAND`, `CNI_CONTAINERID`, `CNI_NETNS`, `CNI_IFNAME`, `CNI_PATH` and `CNI_ARGS`.
    * A minified version of the CNI configuration file (excluding any other plugins).

The last step, if done manually, would look something like this:

```bash
CNI_COMMAND=ADD \
CNI_CONTAINERID=cid \
CNI_NETNS=/var/run/netns/id \
CNI_IFNAME=eth0 \
CNI_PATH=/opt/bin/bin \
CNI_ARGS=K8S_POD_NAMESPACE=foo;K8S_POD_NAME=bar; \
cni_plugin < /etc/cni/net.d/01-cni.conf
```

The CNI plugin then does all of the required interface plumbing and IP allocation and returns back (prints to stdout) the resulting [data structure](https://github.com/containernetworking/cni/blob/master/SPEC.md#result). In the case of plugin chaining, all this information (original inputs + result) gets passed to all plugins along the chain.

Despite its design simplicity, unless you have something else that takes care of establishing end-to-end reachability (e.g. cloud controller), a CNI binary must be accompanied by a long-running stateful daemon/agent. This daemon usually runs in the root network namespace and manages the Node's network stack between CNI binary invocations -- at the very least it adds and removes static routes as Nodes are added to or removed from the cluster. Its operation is not dictated by any standard and the only requirement is to establish Pod-to-Pod reachability. 

{{% notice note %}}
In reality, this daemon does a lot more than just manage reachability and may include a kube-proxy replacement, Kubernetes controller, IPAM etc.
{{% /notice %}}


{{% notice tip %}}
See [meshnet-cni](https://github.com/networkop/meshnet-cni#architecture) for an example of binary+daemon architecture.
{{% /notice %}}



## What to know more?

To learn more about CNI, you can search for the "Kubernetes and the CNI: Where We Are and What's Next", which I cannot recommend highly enough. It is what's shaped my current view of the CNI and heavily inspired the current article. Some other links I can recommend:

* [Slides: Kubernetes and the CNI: Where We Are and What's Next](https://www.caseyc.net/cni-talk-kubecon-18.pdf)
* [CNI Specificaion](https://github.com/containernetworking/cni/blob/master/SPEC.md)
* [CNI plugin implemented in bash](https://www.altoros.com/blog/kubernetes-networking-writing-your-own-simple-cni-plug-in-with-bash/)
* [EVPN CNI plugin](http://logingood.github.io/kubernetes/cni/2016/05/14/netns-and-cni.html)
* [Writing your first CNI plugin](http://dougbtv.com/nfvpe/2017/06/22/cni-tutorial/)
* [Building a meshnet-cni](https://networkop.co.uk/post/2018-11-k8s-topo-p1/)
* [CNI plugin chaining](https://karampok.me/posts/chained-plugins-cni/)
