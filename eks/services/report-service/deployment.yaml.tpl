apiVersion: apps/v1
kind: Deployment
metadata:
  name: report-service
  namespace: default
  labels:
    app: report-service
spec:
  replicas: ${replicas}
  selector:
    matchLabels:
      app: report-service
  template:
    metadata:
      labels:
        app: report-service
    spec:
      containers:
        - name: report-service
          image: ${account_id}.dkr.ecr.${region}.amazonaws.com/report-service:${image_tag}
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
              value: "report-service"
