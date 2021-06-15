---
title: "Control Plane"
date: 2020-09-13T17:33:04+01:00
weight: 40
---

Let's start our explanation with the first stage of any Kubernetes cluster lifecycle -- bootstrapping. At this stage, cluster admin is expected to provide a number of parameters one of which will be called `service-cidr` or something similar depending on the orchestrator. 
{{% notice note %}}
For the simplicity we'll assume `kubeadm` is used to orchestrate a cluster.
{{% /notice %}}

This setting is ultimately used as an `service-cluster-ip-range` argument of the `kube-apiserver` Pods. Orchestrators will suggest a default value for this range (e.g. `10.96.0.0/12`) which most of the times is safe to use, as we'll see later, this range is completely "virtual", i.e. does not need to have any coordination with the underlying network and can be re-used between clusters (one notable exception being [this Calico feature](https://docs.projectcalico.org/networking/advertise-service-ips#advertise-service-cluster-ip-addresses)). The only constraints are:

- It must not overlap with any of the Pod IP ranges or Node IPs of the same cluster.
- It must not be loopback (127.0.0.0/8 for IPv4, ::1/128 for IPv6) or link-local (169.254.0.0/16 and 224.0.0.0/24 for IPv4, fe80::/64 for IPv6).

Once the Kubernetes control plane has been bootstrapped every new `ClusterIP` ServiceType will get a unique IP allocated from this range:


```yaml
$ kubectl create svc clusterip test --tcp=80 && kubectl get svc test
service/test created
NAME   TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)   AGE
test   ClusterIP   10.96.37.70   <none>        80/TCP    0s
```

{{% notice info %}}
The first IP from this range is reserved and always assigned to a special `kubernetes` service. See [this explanation](https://networkop.co.uk/post/2020-06-kubernetes-default/) for more details.
{{% /notice %}}


The main Service/Endpoints controller [reconciliation loop](https://github.com/kubernetes/kubernetes/blob/52eea971c57580c6b1b74f0a12bf9cc6083a4d6b/pkg/controller/endpoint/endpoints_controller.go#L378) builds an internal state for each service which includes a list of all associated Endpoints. There are two ways these Endpoints are determined:


- **Label selectors** allow Service controllers [identify](https://github.com/kubernetes/kubernetes/blob/52eea971c57580c6b1b74f0a12bf9cc6083a4d6b/pkg/controller/endpoint/endpoints_controller.go#L414) all matching Pods, and collect their IP and port information.
- **Manual configuration** relies on users to assemble their own `ClusterIP` service; this approach is very rarely used but can enable intra-cluster addresses for services located outside of the cluster.

All Endpoints are stored in an `Endpoints` resource that bears the same name as its parent Service. Below is an example of how it might look like for the `kubernetes` service:

```yaml
apiVersion: v1
kind: Endpoints
metadata:
  labels:
    endpointslice.kubernetes.io/skip-mirror: "true"
  name: kubernetes
  namespace: default
subsets:
- addresses:
  - ip: 172.18.0.4
  ports:
  - name: https
    port: 6443
    protocol: TCP
```

{{% notice info %}}
Under the hood Endpoints implemented as a set of slices; this will be covered in the Optimisations sections.
{{% /notice %}}

It is worth mentioning that the [DNS Spec](https://github.com/kubernetes/dns/blob/master/docs/specification.md#23---records-for-a-service-with-clusterip), mentioned briefly in the previous chapter, also defines the behaviour for `ClusterIP` type services. Specifically the following 3 query types must be supported:

* A/AAAA Records -- will return a single ClusterIP for any query matching the Service Name in the same namespace or `<service>.<ns>.svc.<zone>` in a different namespace.
* SRV Record -- will return an SRV record for each unique port + protocol combination.
* PTR Record -- can be used to lookup a service name based on provided `ClusterIP`.


---

All of the Service and Endpoints information is collected, processed and is constantly kept in sync by the main `kube-controller-manager`, however nothing is being done with it yet. The final step is when it is synchronised by the node-local agents (controllers) that will use this information to program the nodes' dataplanes. Internal architecture of these node-local agents is implementation-specific and won't be covered in much details here, however some performance and scale-related details are still worth mentioning:
* Node-local agents maintain a local cache of all interesting objects, which gets sync'ed in the beginning (via `List` operation) and observed for the remainder of the agents' lifecycle (via `Watch` operation).
* Every new update is alwas put in local cache, this way frequent changes to the same object can be absorbed and a controller can act based on the last observed state.


{{% notice info %}}
All of the above optimisations are not unique to the networking controllers and are common benefits of all client-go based controllers ([see this](https://github.com/kubernetes/sample-controller/blob/master/docs/controller-client-go.md)).
{{% /notice %}}
