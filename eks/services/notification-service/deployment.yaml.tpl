apiVersion: apps/v1
kind: Deployment
metadata:
  name: notification-service
  namespace: default
  labels:
    app: notification-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: notification-service
  template:
    metadata:
      labels:
        app: notification-service
    spec:
      containers:
        - name: notification-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/notification-service:${image_tag}
          ports:
            - containerPort: ${port}
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
             limits:
              cpu: "250m"
              memory: "256Mi"
          env:
            - name: SERVICE_NAME
              value: "notification-service"
