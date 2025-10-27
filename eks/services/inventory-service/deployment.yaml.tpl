apiVersion: apps/v1
kind: Deployment
metadata:
  name: inventory-service
  namespace: default
  labels:
    app: inventory-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: inventory-service
  template:
    metadata:
      labels:
        app: inventory-service
    spec:
      containers:
        - name: inventory-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/inventory-service:${image_tag}
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
              value: "inventory-service"
