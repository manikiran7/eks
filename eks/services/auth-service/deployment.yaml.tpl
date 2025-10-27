apiVersion: apps/v1
kind: Deployment
metadata:
  name: auth-service
  namespace: default
  labels:
    app: auth-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: auth-service
  template:
    metadata:
      labels:
        app: auth-service
    spec:
      containers:
        - name: auth-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/auth-service:${image_tag}
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
              value: "auth-service"
