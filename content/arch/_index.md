---
title: The Kubernetes Network Model
menuTitle: Network Model
weight: 5
summary: "High-level overview of cluster networking components"
---

The [official documentation](https://kubernetes.io/docs/concepts/cluster-administration/networking/#the-kubernetes-network-model) does a very good job of describing the cluster network assumptions and requirements. I'll repeat the main ideas here for completeness and to lay the foundation for the rest of the article. Kubernetes networking can be seen as several (more or less) orthogonal problems:

* **Local** communications between containers in the same Pod -- solved by the local loopback interface.
* **Pod-to-Pod** East-West communication -- solved by a CNI plugin and discussed in the [CNI](/cni/) chapter of this guide.
* Multi-pod **service** abstraction -- a way to group similar Pods and load-balance traffic to them, discussed in the [Services](/services/)
 chapter of this guide.
* **Ingress** & Egress communication -- getting the traffic in and out of the Kubernetes cluster, discussed in the [Ingress & Egress](/ingress/) chapter of this guide.

In addition to the above, there are a number of auxiliary problems that are covered in their separate chapters:

* **Network Policies** -- a way to filter traffic going to and from Pods.
* **DNS** -- the foundation of cluster service discovery.
* **IPv6** -- unfortunately still requires a separate chapter to discuss the multitude of caveats and limitations.

Despite their orthogonality, each layer builds on top of abstractions provided by another, for example:

* **Ingress** -- associates a URL with a backend Service, learns the associated Endpoints and sends the traffic to one of the PodIPs, relying on the Pod-to-Pod connectivity. 
* **Service** -- performs the client-side load-balancing on the originating Node and sends the traffic to the destination PodIP, effectively relying on the Node-to-Pod connectivity.

Here's an example of how different Kubernetes Resources are stacked together to provide a **North-South** connectivity:

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=ydZ7vDq7JmuY7Tl_GMgH&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}

While the above is the canonical way of exposing an application in Kubernetes, it is by no way the only one. Like in any typical cloud infrastructure, the functions of different layers overlap and, thus, create a space for additional deployment scenarios:

* **Ingress** can **proxy TCP and UDP** traffic to the backend ports. This works handy when the application protocol is not HTTP or if you want to string multiple Ingress proxies together. While Ingress controllers support this through custom [ConfigMaps](https://kubernetes.github.io/ingress-nginx/user-guide/exposing-tcp-udp-services/) or [annotations](https://docs.citrix.com/en-us/citrix-k8s-ingress-controller/how-to/tcp-udp-ingress.html), the gateway API project (which can be viewed as an evolution of Ingress) supports these features [natively](https://gateway-api.sigs.k8s.io/guides/tcp/).
* **Service** of type **LoadBalancer or NodePort** can be used to expose backend ports without an Ingress. This can be useful when the pods need to expose an esoteric protocol (e.g. NETCONF) or when application proxy functions are simply not needed, e.g. small-scale, internal cluster, with not need for TLS termination or traffic rate-limiting.


{{% notice note %}}
The main point is that Kubernetes Networking is not just a CNI or a kube-proxy or an Ingress controller. It's all of the above working in unison to provide a consistent network abstraction for hosted applications and external users.
{{% /notice %}}