# automatic-billing-disable-script
This script ensures that if a specified monthly threshold amount is exceeded, the associated billing account will be automatically detached from the project. This functionality is implemented using Terraform.

Instructions for Running the Scripts -

Please find the Google doc link below, which includes all the detailed steps needed to execute the scripts:
https://docs.google.com/document/d/1vayiDX0cRPV5mK7PEUv-N6Y_ccnDVkXJ8yKuDdeKokM/edit?tab=t.0

# Automatic Billing disable terraform Scripts

Steps to successfully run terraform script via Cloudshell

Prerequisite - 

Owner Privilege users on the project can only be able to execute.

List of the script and dependencies -

	1.  main.py 
	2.  variables.tf
	3. terraform.tfvars
	4.  budget_alert_function.zip 

Script Details - 

main.py Defines GCP resources including APIs, Pub/Sub, billing budget, storage bucket, Cloud Function, and required IAM roles.
variables.tf Declares and documents all input variables needed for resource creation, including defaults and descriptions.
terraform.tfvars Contains configuration variables for billing account, project ID, region, Cloud Function parameters, and other resource names.
budget_alert_function.zip Contains the Cloud Function code to automatically disable billing when budget thresholds are reached.
Steps to execute the script - 
Login to your Google console and set the project - 


Spin up the cloudshell by clicking Activate cloud shell to the top right corner.


Clone the github repository by running these commands - git clone https://github.com/Cloud-Evonence/automatic-billing-disable-script.git



Change directory to - cd automatic-billing-disable-script
Changes needs to be made in main.py -
Run the command to open in an vim editor - vim main.tf 
Currency_code: It’s the currency code by default is USD.(If it’s other than USD than needs to changed use - https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/billing_budget#currency_code-1) 
units: It’s the target amount in specified. (Needs to changed)
Run the command to save the changes in an vim editor - :wq + Enter		

Changes needs to be made in terraform.tfvars -
Run the command to open in an vim editor - vim main.tf 
PROJECT_ID: The ID of your Google Cloud project where the infrastructure will get deployed . (Needs to changed)
Billing account: The billing account ID with the Google Cloud project is attached. (Needs to changed)
Run the command to save the changes in an vim editor - :wq + Enter

No change needs to be made in variable.tf-
Make sure budget_alert_function.zip file should be in same directory as other 3 files-
Command to execute this scripts - 
terraform init
terraform plan
terraform apply
Provide Yes/Y to every prompt pop up till completion of script. 




