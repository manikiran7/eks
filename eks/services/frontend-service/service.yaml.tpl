apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-frontend-service
  namespace: default
  labels:
    app: frontend-service
spec:
  type: ClusterIP
  selector:
    app: frontend-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
