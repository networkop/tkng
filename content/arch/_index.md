---
title: The Kubernetes Network Model
menuTitle: Architecture
weight: 5
summary: "High-level overview of cluster networking components"
---

The [official documentation](https://kubernetes.io/docs/concepts/cluster-administration/networking/#the-kubernetes-network-model) does a very good job of describing the cluster network assumptions and requirements. I'll repeat the main ideas here for completeness and to lay the foundation for the rest of the article. Kubernetes networking can be seen as several (more or less) orthogonal problems:

* **Local** communications between containers in the same Pod -- solved by the local loopback interface.
* **Pod-to-Pod** East-West communication -- solved by a CNI plugin and discussed in the [CNI](/cni/) chapter of this guide.
* Multi-pod **service** abstraction -- a way to group similar Pods and load-balance traffic to them, discussed in the [Services](/services/)
 chapter of this guide.
* **Ingress** & Egress communication -- getting the traffic in and out of the Kubernetes cluster, discussed in the [Ingress & Egress](/ingress/) chapter of this guide.

In addition to the above, there are a number of auxiliary problems that are covered in separate chapter of this guide:

* **Network Policies** -- a way to filter traffic going to and from Pods.
* **DNS** -- the foundation of cluster service discovery.
* **IPv6** -- unfortunately still requires a separate chapter to discuss the multitude of caveats and limitations.

Despite their orthogonality, each layer builds on top of abstractions provided by another, for example:

* **Ingress** -- associates a URL with a backend Service, learns the associated Endpoints and sends the traffic to one of the PodIPs, relying on the Pod-to-Pod connectivity.
* **Service** -- performs the client-side load-balancing on the originating Node and sends the traffic to the destination PodIP, effectively relying on the Node-to-Pod connectivity.

{{% notice note %}}
The main point is that Kubernetes Networking is not just a CNI or kube-proxy or Ingress controller. It's all of the above working in unison to provide a consistent network abstraction for hosted applications and external users.
{{% /notice %}}