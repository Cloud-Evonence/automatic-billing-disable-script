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
