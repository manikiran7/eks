apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-payment-service
  namespace: default
  labels:
    app: payment-service
spec:
  type: ClusterIP
  selector:
    app: payment-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
