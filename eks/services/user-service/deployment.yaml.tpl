apiVersion: apps/v1
kind: Deployment
metadata:
  name: user-service
  namespace: default
  labels:
    app: user-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: user-service
  template:
    metadata:
      labels:
        app: user-service
    spec:
      containers:
        - name: user-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/user-service:${image_tag}
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
              value: "user-service"
