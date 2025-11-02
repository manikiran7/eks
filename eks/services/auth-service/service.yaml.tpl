apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-auth-service
  namespace: default
  labels:
    app: auth-service
spec:
  type: ClusterIP
  selector:
    app: auth-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
