apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-order-service
  namespace: default
  labels:
    app: order-service
spec:
  type: ClusterIP
  selector:
    app: order-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
