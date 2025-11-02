apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-user-service
  namespace: default
  labels:
    app: user-service
spec:
  type: ClusterIP
  selector:
    app: user-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
