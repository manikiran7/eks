apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-analytics-service
  namespace: default
  labels:
    app: analytics-service
spec:
  type: ClusterIP
  selector:
    app: analytics-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
