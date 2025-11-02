apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-report-service
  namespace: default
  labels:
    app: report-service
spec:
  type: ClusterIP
  selector:
    app: report-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
