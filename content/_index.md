---
title: "The Kubernetes Networking Guide"
---

# The Kubernetes Networking Guide

The purpose of this website is to provide an overview of various **Kubernetes networking components** with specific focus on **exactly how** they implement the required functionality. 

The information here can be used for educational purposes, however the main goal is to provide a single point of reference for designing, operating and troubleshooting cluster networking solutions.

{{% notice warning %}}
This is not a generic Kubernetes learning resource. The assumption is that the reader is already familiar with basic concepts and building blocks of a Kubernetes cluster -- pods, deployments, services. 
{{% /notice %}}



## Structure

The guide is split into multiple parts which can be studied mostly independently, however they all work together to provide a complete end-to-end cluster network abstractions.

{{% children description="true" %}}
{{% /children  %}}

{{% notice info %}}
**Why this structure?** -- To explain Kubernetes from a network-centric view in a language understandable to people with traditional network engineering background. This structure is also based on how [#sig-network](https://github.com/kubernetes/community/tree/master/sig-network) is organised into interest groups.
{{% /notice %}}


## Hands-on Labs {#labs}

Where possible, every topic in this guide will include a dedicated hands-on lab which can be spun up locally in a matter of minutes. Refer to the [Lab](lab/) page for setup instructions.



## Contributing
If you found an error or want to add something to this guide, just click the **Edit this page** link displayed on top right of each page (except this one), and submit a pull request.

{{% notice note %}}
When submitting a brand new content, please make an effort to add a corresponding lab to the [Labs repo](https://github.com/networkop/k8s-guide-labs)
{{% /notice %}}


