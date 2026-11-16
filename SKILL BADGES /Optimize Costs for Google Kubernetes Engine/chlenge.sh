export PROJECT_ID=$(gcloud config get-value project)
read -p "Enter Zone: " ZONE
read -p "Enter Cluster Name: " CLUSTER
read -p "Enter Pool Name: " POOL
read -p "Enter Maximum Replicas: " MAXR

gcloud container clusters create $CLUSTER --zone $ZONE --machine-type e2-standard-2 --num-nodes 2 --release-channel rapid
gcloud container clusters get-credentials $CLUSTER --zone $ZONE
kubectl create namespace dev
kubectl create namespace prod
git clone https://github.com/GoogleCloudPlatform/microservices-demo.git && cd microservices-demo && kubectl apply -f ./release/kubernetes-manifests.yaml --namespace dev
kubectl wait --for=condition=available deployment --all -n dev --timeout=300s

gcloud container node-pools create $POOL --cluster $CLUSTER --zone $ZONE --machine-type e2-custom-2-3584 --num-nodes 2
kubectl cordon -l cloud.google.com/gke-nodepool=default-pool
kubectl drain -l cloud.google.com/gke-nodepool=default-pool --ignore-daemonsets --delete-emptydir-data --force
kubectl wait --for=condition=available deployment --all -n dev --timeout=300s
gcloud container node-pools delete default-pool --cluster $CLUSTER --zone $ZONE --quiet

kubectl create poddisruptionbudget onlineboutique-frontend-pdb --selector=app=frontend --min-available=1 -n dev
kubectl set image deployment/frontend server=gcr.io/qwiklabs-resources/onlineboutique-frontend:v2.1 -n dev
kubectl patch deployment frontend -n dev -p '{"spec":{"template":{"spec":{"containers":[{"name":"server","imagePullPolicy":"Always"}]}}}}'
kubectl rollout status deployment/frontend -n dev

kubectl autoscale deployment frontend --cpu-percent=50 --min=1 --max=$MAXR -n dev
gcloud container clusters update $CLUSTER --zone $ZONE --node-pool $POOL --enable-autoscaling --min-nodes 1 --max-nodes 6
kubectl autoscale deployment recommendationservice --cpu-percent=50 --min=1 --max=5 -n dev

FRONTEND_IP=$(kubectl get svc frontend-external -n dev -o jsonpath='{.status.loadBalancer.ingress[0].ip}'); echo $FRONTEND_IP
kubectl exec $(kubectl get pod --namespace=dev | grep 'loadgenerator' | cut -f1 -d ' ') -it --namespace=dev -- sh -c "export USERS=8000; locust --host=\"http://$FRONTEND_IP\" --headless -u \"8000\" 2>&1"
