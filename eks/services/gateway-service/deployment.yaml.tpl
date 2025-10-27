apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway-service
  namespace: default
  labels:
    app: gateway-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: gateway-service
  template:
    metadata:
      labels:
        app: gateway-service
    spec:
      containers:
        - name: gateway-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/gateway-service:${image_tag}
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
              value: "gateway-service"
