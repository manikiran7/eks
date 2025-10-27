apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend-service
  namespace: default
  labels:
    app: frontend-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: frontend-service
  template:
    metadata:
      labels:
        app: frontend-service
    spec:
      containers:
        - name: frontend-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/frontend-service:${image_tag}
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
              value: "frontend-service"
