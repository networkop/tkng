---
title: "Data Plane"
date: 2020-09-13T17:33:04+01:00
weight: 40
---

This topic is one of the most complicated in this book 



```
apiVersion: v1
kind: Service
metadata:
  name: clusterIP-example
spec:
  clusterIP: 10.96.202.14
  ports:
  - name: http
    port: 80
    targetPort: 8500
  selector:
    app: my-backend-app
```

https://docs.google.com/drawings/d/1MtWL8qRTs6PlnJrW4dh8135_S9e2SaawT410bJuoBPk/edit

[appProtocol](https://github.com/kubernetes/enhancements/tree/master/keps/sig-network/1507-app-protocol)