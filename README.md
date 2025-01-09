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
   
3. **`terraform.tfvars`**  
   - Configuration variables for:
     - Billing account
     - Project ID
     - Region
     - Cloud Function parameters
     - Resource names
   
4. **`budget_alert_function.zip`**  
   - Contains Cloud Function code to disable billing when budget thresholds are reached.

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
### Step 3: Edit **`main.py`** 
Run the following commands in Cloud Shell:
```bash
vim main.tf
```
Update the following fields:
 - Currency Code:
     - Default: USD
     - Change if your project uses a different currency. Refer to the Terraform Docs, link - https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/billing_budget#currency_code-1
 - Units:
     - Specify the target budget amount.

Run the following commands in Cloud Shell to save the file:
 ```bash
 :wq
 ```
### Step 4: Edit **`terraform.tfvars`**
Run the following commands in Cloud Shell:
```bash
vim terraform.tfvars
```
Update the following fields:
  - Project_ID:
     - Your Google Cloud project ID.
  - Billing Account:
     - Your Google Cloud billing account ID.
Save and Close the file:
```bash
 :wq
```

### Step 5: Confirm File Placement 
Ensure that **`budget_alert_function.zip`**  is in the same directory as the other three files.

### Step 6: Initialize Terraform
Run the following commands in Cloud Shell:
```bash
terraform init
```

### Step 7: Plan the Deployment Terraform
Run the following commands in Cloud Shell:
```bash
terraform plan
```

### Step 8: Apply the Terraform Script
Run the following commands in Cloud Shell:
```bash
terraform apply
```

--

### Step 9: Verify the Setup
Update the following fields:
  - Open the Google Cloud Console 
  - Navigate to the Billing section
  - Check if the billing budget and associated resources (Cloud Function, Pub/Sub topic, etc.) have been successfully created.

---

## 📖 Additional Resources
For detailed instructions, refer to the Google Doc - https://docs.google.com/document/d/1vayiDX0cRPV5mK7PEUv-N6Y_ccnDVkXJ8yKuDdeKokM/edit?tab=t.0

---
