apiVersion: apps/v1
kind: Deployment
metadata:
  name: analytics-service
  namespace: default
  labels:
    app: analytics-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: analytics-service
  template:
    metadata:
      labels:
        app: analytics-service
    spec:
      containers:
        - name: analytics-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/analytics-service:${image_tag}
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
              value: "analytics-service"
