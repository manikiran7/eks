apiVersion: apps/v1
kind: Deployment
metadata:
  name: payment-service
  namespace: default
  labels:
    app: payment-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: payment-service
  template:
    metadata:
      labels:
        app: payment-service
    spec:
      containers:
        - name: payment-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/payment-service:${image_tag}
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
              value: "payment-service"
