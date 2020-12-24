---
title: "Lab Setup"
menutitle: "Lab Setup"
date: 2020-09-13T17:33:04+01:00
summary: "Prerequisites and setup of the lab environment"
---

{{% notice info %}}
All labs are stored in a separate Github repository -- [k8s-guide-labs](https://github.com/networkop/k8s-guide-labs)
{{% /notice %}}

## Prerequisites

In order to interact with the labs, the following set of tools need to be pre-installed:

* **Docker** with `containerd` runtime. This is what you get by default when you install [docker-ce](https://docs.docker.com/engine/install/).
* **kubectl** to interact with a Kubernetes cluster. Installation instructions can be found [here](https://kubernetes.io/docs/tasks/tools/install-kubectl/).
* **helm** to bootstrap the cluster with Flux. Installation instructions can be found [here](https://github.com/helm/helm#install)
* **make** is used to automate and orchestrate manual tasks. Most instructions will be provided as a series of make commands.

{{% notice info %}}
A number of additional tools (e.g. kind) will be installed automatically during the Setup phase
{{% /notice %}}

Some **optional extras** that may make your life a lot easier:

* [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/#optional-kubectl-configurations) and [docker](https://github.com/docker/docker-ce/tree/master/components/cli/contrib/completion) commands auto-completion.
* [kubens/kubectx](https://github.com/ahmetb/kubectx) to easily switch between namespaces and contexts.
* [stern](https://github.com/wercker/stern) to read logs from multiple Pods at the same time.
* [k9s](https://github.com/derailed/k9s) is a very convinient terminal dashboard for a Kubernetes cluster.

## Supported Operating Systems

The main supported operating system is **Linux**. The kernel version can be anything that's `>=4.19`.

{{% notice note %}}
Most of the things should also be supported on Darwin. If you find a discrepancy and know how to fix it, please submit a PR.
{{% /notice %}}


## Setup instructions

Clone the k8s-guide-labs repository:

```bash
git clone https://github.com/networkop/k8s-guide-labs.git && cd k8s-guide-labs
```

To view the list of available operations do:

```bash
$ make  

check           Check prerequisites 
setup           Setup the lab environment 
up              Bring up the cluster 
connect         Connect to Weave Scope 
tshoot          Connect to the troubleshooting pod 
reset           Reset k8s cluster 
down            Shutdown 
cleanup         Destroy the lab environment 
```

Check and install the required prerequisites:

```bash
$ make check
all good
```

Setup the lab environment with:

```bash
make setup
```

Finally, bootstrap the cluster with Flux:


```bash
make up
```

{{% notice tip %}}
All labs are built in [GitOps](https://www.weave.works/technologies/gitops/) style using [Flux](https://github.com/fluxcd/flux) as the controller that manages the state of the cluster. 
{{% /notice %}}

## Interacting with the Lab

The lab consists of a local Kubernetes cluster along with a caching pull-through Docker registry to speed up download times. The cluster is built with [kind](https://github.com/kubernetes-sigs/kind) and the caching registry is a standalone container running alongside of it.

To build the cluster for the first time run:

```
make up
```

In order to stop the cluster (e.g. to free up resources) run:

```
make down
````

In order to rebuild the cluster (combined `up` and `down`) run:

```
make reset
```

To completely destroy the lab environment, including the caching registry run:


```
make cleanup
```


## Default applications

The lab cluster is setup with a couple of applications that will be used throughout this guide:

1. **[Weave Scope](https://github.com/weaveworks/scope)** -- a tool to visualise and monitor Kubernetes cluster workloads.

{{% notice tip %}}
To connect to Weave Scope's front-end, run `make connect` and go to [http://localhost:8080](http://localhost:8080)
{{% /notice %}}


2. **[netshoot](https://github.com/nicolaka/netshoot)** -- deployed as a Daemonset, a docker image pre-installed with a wide range of network troubleshooting tools.

{{% notice tip %}}
To connect to a Pod running on a particular Node (e.g. k8s-guide-worker), run `NODE=k8s-guide-worker make tshoot`
{{% /notice %}}
