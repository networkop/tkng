---
title: "Ingress & Egress"
date: 2020-09-13T17:33:04+01:00
weight: 70
summary: "North-South traffic forwarding"
---

This chapter deals with anything related to North-South traffic forwarding in Kubernetes. First, let's make it clear that in both ingress (North) and egress (South) cases, traffic flows are actually bidirectional, i.e. a single flow would have packets flowing in both directions. The main distiction between ingress and egress is the direction of the original packet, i.e. where the client and server are located relative to the Kubernetes cluster boundary. 

These two types of traffic are treated very diffirently and almost always take asymmetric paths. This is because ingress is usually more important -- it's the revenue-generating user traffic for cluster applications, while egress is mainly non-revenue, Internet-bound traffic, e.g. DNS queries, package updates -- something that may not even be needed, depending on the application architecture.

{{% notice note %}}
Egress may have a slightly different meaning in the context of service meshes and multiple clusters, but this is outside of the scope of this chapter.
{{% /notice %}}


Because of the above differences, ingress and egress traffic needs to be examined separately and this chapter will be split into the following subchapters:

* **Ingress API** -- the original method of routing incoming traffic to different cluster applications.
* **Gateway API** -- can be treated as the evolution of the Ingress API with the same goals and scope.
* **Egress** -- describes different options for egress traffic engineering.


