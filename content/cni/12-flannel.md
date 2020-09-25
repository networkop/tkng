---
title: "flannel"
menuTitle: "flannel"
date: 2020-09-13T17:33:04+01:00
weight: 12
---

# Design

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=edFgbkK8AGV7w_fFUyD5&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}

### Lab

```
make flannel
```

One the flannel daemonset has transitioned to `Running` do:

```
make nuke-all-pods
```