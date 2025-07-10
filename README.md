# Automatic Billing Disable Script

This repository contains a Terraform script that automatically detaches the billing account from a project if the specified monthly threshold is exceeded.

---

## 📝 Overview

This script automates billing account management by detaching the billing account when a specified threshold is reached. It utilizes GCP resources, Pub/Sub, a Cloud Function, and Terraform.

---

## 🚀 Getting Started

### **Prerequisite**
- **Owner Privileges:** Only users with **owner privileges** on the project can execute this script.

---

## 📂 Contents

### **Scripts and Dependencies**
1. **`main.py`**  
   - Defines GCP resources, including APIs, Pub/Sub, billing budget, storage bucket, Cloud Function, and IAM roles.
   
2. **`variables.tf`**  
   - Documents and declares input variables for resource creation, including defaults and descriptions.
   
3. **`deploy.sh`**  
   - Bootstrap & deploy script which:
      - Creates (or verifies) the GCS bucket for Terraform state and enables uniform ACLs and versioning  
      - Initializes Terraform with the correct backend  
      - Applies the Terraform configuration with `--auto-approve`

4. **`backend.tf`**  
   - Contains Cloud Function code to disable billing when budget thresholds are reached.
   
5. **`budget_alert_function.zip`**  
   - Configures the Terraform backend, specifying the GCS bucket, prefix, and state locking settings.

---

## 🛠️ Setup and Execution

### Step 1: Environment Setup
1. Log in to your [Google Cloud Console](https://console.cloud.google.com/).
2. Activate Cloud Shell by clicking **Activate Cloud Shell** in the top-right corner.

### Step 2: Clone the Repository
Run the following commands in Cloud Shell:  
```bash
git clone https://github.com/Cloud-Evonence/automatic-billing-disable-script.git
cd automatic-billing-disable-script
```
### Step 3: Bootstrap & Deploy with **`deploy.sh`** 
Run the following commands in Cloud Shell:

Replace "my-project_id" with your Google Cloud project ID:
```bash
gcloud config set project "my-project-id" 
```
```bash
chmod +x deploy.sh
./deploy.sh 
```

> **Note:** You will be prompted for your billing account ID, project ID, budget amount, and currency during execution.

Update the following fields:
  - Project_ID:
     - Your Google Cloud project ID.
  - Billing Account:
     - Your Google Cloud billing account ID.
 - Currency Code:
     - Default: USD
     - Change if your project uses a different currency. Refer to the Terraform Docs, link - https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/billing_budget#currency_code-1
 - Units:
     - Specify the target budget amount.

### Step 4: Verify the Setup
Update the following fields:
  - Open the Google Cloud Console 
  - Navigate to the Billing section
  - Check if the billing budget and associated resources (Cloud Function, Pub/Sub topic, etc.) have been successfully created.

---

## 🔄 Cleanup

To remove all resources created by this script:
```bash
terraform destroy --auto-approve
```
---
## 📖 Additional Resources
For detailed instructions, refer to the Google Doc - https://docs.google.com/document/d/1vayiDX0cRPV5mK7PEUv-N6Y_ccnDVkXJ8yKuDdeKokM/edit?tab=t.0

---

