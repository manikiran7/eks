apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-inventory-service
  namespace: default
  labels:
    app: inventory-service
spec:
  type: ClusterIP
  selector:
    app: inventory-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
