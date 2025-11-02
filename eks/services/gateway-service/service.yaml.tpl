apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-gateway-service
  namespace: default
  labels:
    app: gateway-service
spec:
  type: ClusterIP
  selector:
    app: gateway-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
