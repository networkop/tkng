---
title: "Gateway API"
date: 2020-09-13T17:33:04+01:00
weight: 20
summary: "Evolution of Ingress API"
---

Ingress API has had a very difficult history and had remained in `v1beta1` for many years. Despite having a thriving ecosystem of controller implementations, their use of Ingress API have remained largely incompatible. In addition to that, the same controller vendors have started shipping their own set of custom resources designed to address the limitations of Ingress API. At some point Kubernetes SIG Network group even discussed the possibility of scrapping the Ingress API altogether and letting each vendor bring their own set of CRDs (see "Ingress Discussion Notes" in [Network SIG Meeting Minutes](https://docs.google.com/document/d/1_w77-zG_Xj0zYvEMfQZTQ-wPP4kXkpGD8smVtW_qqWM/edit)). Despite all that, Ingress API has survived, addressed some of the more pressing issues and finally got promoted to `v1` in Kuberntes `v1.19`. However some of the problems could not be solved by an incremental re-design and this is why the [Gateway API](https://gateway-api.sigs.k8s.io/) project (formerly called Service API) was founded. 

Gateway API decomposes a single Ingress API into a a set of [independent resources](https://gateway-api.sigs.k8s.io/concepts/api-overview/) that can be combined via label selectors and references to build the desired proxy state. This decomposition follows a pattern very commonly found in proxy configuration -- listener, route and backends -- and can be viewed as a hiererchy of objects:

|Hierarchy | Description |
|--------------|---|
| Gateway Class | Identifies a single GatewayAPI controller installed in a cluster. |
| Gateway | Associates listeners with Routes, belongs to ony of the Gateway classes. |
| Route | Defines rules for traffic routing by linking Gateways with Services. |
| Service | Represents a set of Endpoints to be used a backends. |

This is how the above hierarchy can be combined to expose an existing `web` Service to the outside world as `http://gateway.tkng.io` (see the Lab [walkthrough](http://localhost:1313/ingress/gateway/#walkthrough) for more details):

```yaml
apiVersion: networking.x-k8s.io/v1alpha1
kind: GatewayClass
metadata:
  name: istio
spec:
  controller: istio.io/gateway-controller
---
apiVersion: networking.x-k8s.io/v1alpha1
kind: Gateway
metadata:
  name: gateway
  namespace: istio-system
spec:
  gatewayClassName: istio
  listeners:
  - hostname: "*"
    port: 80
    protocol: HTTP
    routes:
      namespaces:
        from: All
      selector:
        matchLabels:
          selected: "yes"
      kind: HTTPRoute
---
apiVersion: networking.x-k8s.io/v1alpha1
kind: HTTPRoute
metadata:
  name: http
  namespace: default
  labels:
    selected: "yes"
spec:
  gateways:
    allow: All
  hostnames: ["gateway.tkng.io"]
  rules:
  - matches:
    - path:
        type: Prefix
        value: /
    forwardTo:
    - serviceName: web
      port: 80
```

Regardless of all the new features and operational benefits Gateway API brings, its final goal is exactly the same as for Ingress API -- to configure a proxy for external access to applications running in a cluster. 

{{< iframe "https://viewer.diagrams.net/?highlight=0000ff&edit=_blank&hide-pages=1&editable=false&layers=1&nav=0&page-id=872_TPyC9xnwDXYNSrfC&title=k8s-guide.drawio#Uhttps%3A%2F%2Fraw.githubusercontent.com%2Fnetworkop%2Fk8s-guide-labs%2Fmaster%2Fdiagrams%2Fk8s-guide.drawio" >}}


## Lab

For this lab exercise, we'll use one the Gateway API implementation from [Istio](https://kubernetes.github.io/ingress-nginx/). 


### Preparation


Assuming that the lab environment is already [set up](/lab/), `Istio` can be set up with the following commands:


```
make gateway-setup
```

Wait for all Istio Pods to fully initialise:

```
$ make gateway-check
pod/istio-ingressgateway-574dff7b88-9cd7v condition met
pod/istiod-59db6b6d9-pl6np condition met
pod/metallb-controller-748756655f-zqdxn condition met
pod/metallb-speaker-97tb7 condition met
pod/metallb-speaker-pwvrx condition met
pod/metallb-speaker-qln9k condition met
```

Set up a test Deployment to be used in the walkthrough:


```
$ make deployment && make cluster-ip
```

Make sure that the Gateway has been assigned with a LoadBalancer IP:

```
$ kubectl get -n istio-system gateways gateway -o jsonpath='{.status.addresses}' | jq
[
  {
    "type": "IPAddress",
    "value": "198.51.100.0"
  }
]
```

Now we can verify the functionality:

```
$ docker exec k8s-guide-control-plane curl -s -HHost:gateway.tkng.io http://198.51.100.0/ | grep Welcome
<title>Welcome to nginx!</title>
<h1>Welcome to nginx!</h1>
 ```

### Walkthrough

One of the easiest ways to very data plane configuration is to use the [istioctl](https://istio.io/latest/docs/setup/install/istioctl/) tool. The first thing we can do is look at the current state of all data plane proxies. In our case we're not using Istio's service mesh functionality, so the only proxy will be the `istio-ingressgateway`:

```
$ istioctl proxy-status
NAME                                                   CDS        LDS        EDS        RDS        ISTIOD                     VERSION
istio-ingressgateway-574dff7b88-tnqck.istio-system     SYNCED     SYNCED     SYNCED     SYNCED     istiod-59db6b6d9-j8kt8     1.12-alpha.2a768472737998f0e13cfbfec74162005c53300c
```

Let's take a close look at the `proxy-config`, starting with the current set of listeners:

```
$ istioctl proxy-config listener istio-ingressgateway-574dff7b88-tnqck.istio-system
ADDRESS PORT  MATCH DESTINATION
0.0.0.0 8080  ALL   Route: http.8080
0.0.0.0 15021 ALL   Inline Route: /healthz/ready*
0.0.0.0 15090 ALL   Inline Route: /stats/prometheus*
```

The one that we're interested in is called `http.8080` and here how we can check all of the routing currently configured for it:

```json
"istioctl proxy-config route istio-ingressgateway-574dff7b88-tnqck.istio-system --name http.8080 -ojson"
[
    {
        "name": "http.8080",
        "virtualHosts": [
            {
                "name": "gateway.tkng.io:80",
                "domains": [
                    "gateway.tkng.io",
                    "gateway.tkng.io:*"
                ],
                "routes": [
                    {
                        "match": {
                            "prefix": "/",
                            "caseSensitive": true
                        },
                        "route": {
                            "cluster": "outbound|80||web.default.svc.cluster.local",
                            "timeout": "0s",
                            "retryPolicy": {
                                "retryOn": "connect-failure,refused-stream,unavailable,cancelled,retriable-status-codes",
                                "numRetries": 2,
                                "retryHostPredicate": [
                                    {
                                        "name": "envoy.retry_host_predicates.previous_hosts"
                                    }
                                ],
                                "hostSelectionRetryMaxAttempts": "5",
                                "retriableStatusCodes": [
                                    503
                                ]
                            },
                            "maxGrpcTimeout": "0s"
                        },
                        "metadata": {
                            "filterMetadata": {
                                "istio": {
                                    "config": "/apis/networking.istio.io/v1alpha3/namespaces/default/virtual-service/http-istio-autogenerated-k8s-gateway"
                                }
                            }
                        },
                        "decorator": {
                            "operation": "web.default.svc.cluster.local:80/*"
                        }
                    }
                ],
                "includeRequestAttemptCount": true
            }
        ],
        "validateClusters": false
    }
]
```

From the above output we can see that the proxy is set up to route all HTTP requests with `Host: gateway.tkng.io` header to a cluster called `outbound|80||web.default.svc.cluster.local`.  Let's check this cluster's Endpoints:

```
$ istioctl proxy-config endpoints istio-ingressgateway-574dff7b88-tnqck.istio-system  --cluster "outbound|80||web.default.svc.cluster.local"
ENDPOINT           STATUS      OUTLIER CHECK     CLUSTER
10.244.1.12:80     HEALTHY     OK                outbound|80||web.default.svc.cluster.local
```

The above Endpoint address corresponds to the only running Pod in the `web` deployment:

```
$ kubectl get pod -owide -l app=web
NAME                  READY   STATUS    RESTARTS   AGE    IP            NODE               NOMINATED NODE   READINESS GATES
web-96d5df5c8-p8f97   1/1     Running   0          104m   10.244.1.12   k8s-guide-worker   <none>           <none>
```