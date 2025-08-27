# SmartDelivaeryInfra

helm install prometheus prometheus-community/prometheus --namespace monitoring -f prometheus-values.yaml

helm install grafana grafana/grafana --namespace monitoring -f grafana-values.yaml