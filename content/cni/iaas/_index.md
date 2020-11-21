---
title: Public and Private Clouds
menuTitle: "IaaS"
weight: 13
summary: Cloud-based Kubernetes deployments
---

Kubernetes was designed to run inside a cloud environment. The idea is that the IaaS layer can provide resources that Kubernetes can consume without having to implement them internally. These resources include VMs (for Node management), L4 load-balancers (for service type LoadBalancer) and persistent storage (for PersistentVolumes). The reason why it's important for networking is that the underlying cloud SDN is also programmable and can be managed by the Kubernetes itself. 

{{% notice note %}}
Although it is possible to run Kubernetes directly on baremetal, all of these problems will still need to be addressed individually by the cluster administrator.
{{% /notice %}}

## Operation

A typical managed Kubernetes deployment includes a simple CNI plugin called [kubenet](https://kubernetes.io/docs/concepts/extend-kubernetes/compute-storage-net/network-plugins/#kubenet) which is another example of a `metaplugin` -- it [re-uses](https://github.com/kubernetes/kubernetes/blob/master/pkg/kubelet/dockershim/network/kubenet/kubenet_linux.go#L88) `bridge`, `host-local` and `loopback` reference CNI plugins and orchestrates them to provide **connectivity**. 

{{% notice note %}}
It is enabled with a kubelet argument `--network-plugin=kubenet` which, for managed Kubernetes, means that it cannot be replaced with a different CNI plugin.
{{% /notice  %}}


One notable difference with `kubenet` is that there is no daemon component in the plugin. In this case, **reachability** is provided by the underlying SDN and orchestrated by a [Cloud Controller Manager](https://kubernetes.io/docs/concepts/architecture/cloud-controller/). Behind the scenes, for each PodCIDR it installs a **static route** pointing to the Node IP -- this way traffic between Pods can just follow the default route in the root namespace, safely assuming that the underlying virtual router will know where to forward the packets.

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=A5cMEZUylDs-XIrDOgQv&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}

{{% notice note %}}
If you're interested in using BGP to establish reachability in cloud environment, be sure to check out [cloudroutesync](https://github.com/networkop/cloudroutesync).
{{% /notice  %}}


### GKE

Google's CCM uses [IP Alias ranges](https://cloud.google.com/vpc/docs/alias-ip) to provide reachability. The VPC subnet gets configured with a secondary address range that is the same as the cluster CIDR: 

```
$ gcloud compute networks subnets describe private-subnet | grep -A 3 secondaryIpRanges 
secondaryIpRanges:
- ipCidrRange: 10.244.0.0/22
  rangeName: private-secondary
```

Each new Node VM gets created with an alias range set to the Node's PodCIDR:

```
$ gcloud compute instances describe gke-node | grep -A 3 aliasIpRanges
networkInterfaces:
- aliasIpRanges:
  - ipCidrRange: 10.224.1.0/24
    subnetworkRangeName: private-secondary
```

Inside of the Node VM there's a standard set of interfaces:

```
$ ip -4 -br add show
lo               UNKNOWN        127.0.0.1/8
eth0             UP             172.16.0.12/32
cbr0             UP             10.224.1.1/24
```

The routing table only has a single non-directly connected default route:

```
$ ip route 
default via 172.16.0.1 dev eth0 proto dhcp metric 1024 
172.16.0.12 dev eth0 proto dhcp scope link metric 1024 
10.224.1.0/24 dev cbr0 proto kernel scope link src 10.224.1.1 
```

{{% notice info %}}
IP Alias is a special kind of static route that, amongst [other benefits](https://cloud.google.com/vpc/docs/alias-ip#key_benefits_of_alias_ip_ranges), gets checked for potential conflicts and automatically updates the corresponding anti-spoofing rules to allow VM to emit packets with non-native IPs.
{{% /notice %}}

### AKS

Azure uses normal static routes to setup reachability:

```
az network route-table show --ids "id" | grep -A 5 10.224.1.0
      "addressPrefix": "10.224.1.0/24",
      "etag": "W/\"tag\"",
      "id": "id",
      "name": "name",
      "nextHopIpAddress": "172.16.0.12",
      "nextHopType": "VirtualAppliance",
```

Inside of the Node VM there's a standard set of interfaces:


```
# ip -4 -br add show
lo               UNKNOWN        127.0.0.1/8 
eth0             UP             172.16.0.12/16 
cbr0             UP             10.224.1.1/24 
```

And there is only a single non-directly connected route pointing out the primary interface:

```
# ip route
default via 172.16.0.1 dev eth0 
172.16.0.0/16 dev eth0 proto kernel scope link src 172.16.0.12 
10.224.1.0/24 dev cbr0 proto kernel scope link src 10.224.1.1 
168.63.129.16 via 172.16.0.1 dev eth0 
169.254.169.254 via 172.16.0.1 dev eth0 
```

{{% notice info %}}
Azure Nodes can also be configured with ["Azure CNI"](https://docs.microsoft.com/en-us/azure/aks/configure-azure-cni) where Pod IPs get allocated from the same range as the underlying VNET.
{{% /notice %}}


### EKS

EKS takes a slightly different approach and runs as special [AWS CNI plugin](https://github.com/aws/amazon-vpc-cni-k8s) as a daemonset on all nodes. The functionality of this plugin is documented in the [proposal](https://github.com/aws/amazon-vpc-cni-k8s/blob/master/docs/cni-proposal.md) in a lot of detail. 

{{% notice info %}}
The VPC-native routing is achieved by assigning each Node's ENI with secondary IPs, and adding more ENIs as the max number of IPs per ENI [limit](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/using-eni.html#AvailableIpPerENI) is exceeded.
{{% /notice %}}


One thing worth mentioning here is that in EKS's case, it's possible to replace the AWS CNI plugin with a number of [3rd party plugins](https://docs.aws.amazon.com/eks/latest/userguide/alternate-cni-plugins.html). In this case, VPC-native routing is not available since VPC virtual router won't be aware of the PodCIDRs and the only option is to run those plugins in the overlay mode -- by building a full-mesh of VXLAN tunnels and static routes that forward traffic over them.