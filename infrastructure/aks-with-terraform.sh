#!/bin/bash
# from git clone https://github.com/kubernauts/aks-terraform-rancher.git aks-terraform-setup

export SUBSCRIPTION_ID="c38f07ce-04cd-4481-a7a2-967d16cce2e3"
export TERRAFORM_STATE_STORAGE_ACCOUNT="terraformstatesebi"
export TERRAFORM_STATE_CONTAINER="tfstate"
export KEYVAULT_NAME="aks-tf-keyvault"
export AAD_TENANT_ID="a9ebb648-f810-44f9-81f5-a84d59d6bf04"

# get sources
cd aks-terraform-rancher

# login azure cli
az login 
az account set -s $SUBSCRIPTION_ID

# Create a Storage Account to manage terraform state for different clusters
# returns access_key that we need for the next step
source create-azure-storage-account.sh westeurope storage-account-rg ${TERRAFORM_STATE_STORAGE_ACCOUNT} ${TERRAFORM_STATE_CONTAINER}

# Create Azure Key Vault
az group create --name key-vault-rg --location westeurope
az keyvault create --name "${KEYVAULT_NAME}" --resource-group "key-vault-rg" --location "westeurope"
az keyvault secret set --vault-name "${KEYVAULT_NAME}" --name "terraform-backend-key" --value ${ACCOUNT_KEY}
az keyvault secret show --name terraform-backend-key --vault-name ${KEYVAULT_NAME} --query value -o tsv
export ARM_ACCESS_KEY=$(az keyvault secret show --name terraform-backend-key --vault-name ${KEYVAULT_NAME} --query value -o tsv)
echo $ARM_ACCESS_KEY

# Initialise terraform for AKS deployment
terraform init -backend-config="storage_account_name=${TERRAFORM_STATE_STORAGE_ACCOUNT}" -backend-config="container_name=${TERRAFORM_STATE_CONTAINER}" -backend-config="key=aceme-management.${TERRAFORM_STATE_CONTAINER}"

# Create a custom terraform service principal 
# with least privilege to perform the AKS deployment
# will provide "appid"->id and "password"->secret for next command
./createTerraformServicePrincipal.sh

export TF_VAR_client_id=$ARM_CLIENT_ID
export TF_VAR_client_secret=$ARM_CLIENT_SECRET

az keyvault secret set --vault-name "${KEYVAULT_NAME}" --name "TF-VAR-client-id" --value $TF_VAR_client_id
az keyvault secret set --vault-name "${KEYVAULT_NAME}" --name "TF-VAR-client-secret" --value $TF_VAR_client_secret

# Azure Active Directory Authorization
./create-azure-ad-server-app.sh
# Once created you need to ask an Azure AD Administrator to go to the Azure portal 
# and click the Grant permission button for this server app 
# (Active Directory → App registrations (preview) → All applications → AKSAADServer2).
# Click on AKSAADServer2 application → Api permissions → Grant admin consent

source create-azure-ad-client-app.sh

az keyvault secret set — vault-name "${KEYVAULT_NAME}" — name "TF-VAR-rbac-server-app-id" — value $RBAC_SERVER_APP_ID
az keyvault secret set — vault-name "${KEYVAULT_NAME}" — name "TF-VAR-rbac-server-app-secret" — value $RBAC_SERVER_APP_SECRET
az keyvault secret set — vault-name "${KEYVAULT_NAME}" — name "TF-VAR-rbac-client-app-id" — value $RBAC_SERVER_APP_OAUTH2PERMISSIONS_ID
az keyvault secret set — vault-name "${KEYVAULT_NAME}" — name "TF-VAR-tenant-id" — value $RBAC_AZURE_TENANT_ID

export TF_VAR_client_id=$(az keyvault secret show — name TF-VAR-client-id — vault-name ${KEYVAULT_NAME} — query value -o tsv)
export TF_VAR_client_secret=$(az keyvault secret show — name TF-VAR-client-secret — vault-name ${KEYVAULT_NAME} — query value -o tsv)
export TF_VAR_rbac_server_app_id=$(az keyvault secret show — name TF-VAR-rbac-server-app-id — vault-name ${KEYVAULT_NAME} — query value -o tsv)
export TF_VAR_rbac_server_app_secret=$(az keyvault secret show — name TF-VAR-rbac-server-app-secret — vault-name ${KEYVAULT_NAME} — query value -o tsv)
export TF_VAR_rbac_client_app_id=$(az keyvault secret show — name TF-VAR-rbac-client-app-id — vault-name ${KEYVAULT_NAME} — query value -o tsv)
export TF_VAR_tenant_id=$(az keyvault secret show — name TF-VAR-tenant-id — vault-name ${KEYVAULT_NAME} — query value -o tsv)

# Deploy AKS
export ARM_ACCESS_KEY=$(az keyvault secret show --name terraform-backend-key --vault-name ${KEYVAULT_NAME} --query value -o tsv)
source export_tf_vars
terraform plan -out rancher-management-plan
terraform apply rancher-management-plan -auto-approve

# Configure RBAC
az aks get-credentials -n CLUSTER_NAME -g RESOURCE_GROUP_NAME — admin
az aks get-credentials -n k8s-pre-prod -g kafka-pre-prod-rg — admin
k get nodes
kubectl apply -f cluster-admin-rolebinding.yaml

# Connect to the cluster using RBAC and Azure AD
az aks get credentials -n CLUSTER_NAME -g RESOURCE_GROUP_NAME
kubectl get nodes
