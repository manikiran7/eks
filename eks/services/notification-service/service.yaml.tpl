apiVersion: v1
kind: Service
metadata:
  name: ${name_prefix}-notification-service
  namespace: default
  labels:
    app: notification-service
spec:
  type: ClusterIP
  selector:
    app: notification-service
  ports:
    - port: 80
      targetPort: ${port}
      protocol: TCP
