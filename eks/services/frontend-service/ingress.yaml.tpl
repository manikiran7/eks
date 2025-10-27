apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${name_prefix}-${service_name}-ingress
  namespace: default
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/group.name: ${name_prefix}-shared
    alb.ingress.kubernetes.io/load-balancer-name: ${name_prefix}-shared-alb
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80}]'
    alb.ingress.kubernetes.io/healthcheck-protocol: HTTP
    alb.ingress.kubernetes.io/healthcheck-path: /
    alb.ingress.kubernetes.io/healthcheck-port: traffic-port
spec:
  rules:
    - http:
        paths:
          - path: ${path}
            pathType: Prefix
            backend:
              service:
                name: ${service_name}
                port:
                  number: ${port}
