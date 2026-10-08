import base64
import json
import os
import time
import datetime
import functions_framework
from cloudevents.http import CloudEvent
from googleapiclient import discovery

import smtplib
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
import requests

# Environment variables set by Cloud Functions
PROJECT_ID = os.getenv("GCP_PROJECT")
PROJECT_NAME = f"projects/{PROJECT_ID}"
NOTIFICATION_EMAILS = [e.strip() for e in os.getenv("NOTIFICATION_EMAILS", "").split(",") if e.strip()]
NOTIFICATION_SECRET_ID = os.getenv("NOTIFICATION_SECRET_ID", "do-not-delete-billing-notifications")

def __get_notification_secrets():
    """
    Dynamically retrieve Google Chat Webhook URL and SMTP credentials from Secret Manager.
    """
    if not PROJECT_ID:
        return {}
    try:
        from google.cloud import secretmanager
        client = secretmanager.SecretManagerServiceClient()
        name = f"projects/{PROJECT_ID}/secrets/{NOTIFICATION_SECRET_ID}/versions/latest"
        response = client.access_secret_version(request={"name": name})
        payload_str = response.payload.data.decode("UTF-8")
        secrets_data = json.loads(payload_str)
        print("[SECRET MANAGER] Successfully loaded notification credentials from Secret Manager.")
        return secrets_data
    except Exception as e:
        print(f"[SECRET MANAGER WARNING] Could not fetch secret '{NOTIFICATION_SECRET_ID}': {e}. Falling back to environment variables.")
        return {
            "google_chat_webhook_url": os.getenv("GOOGLE_CHAT_WEBHOOK_URL", ""),
            "smtp_host": os.getenv("SMTP_HOST", "smtp.gmail.com"),
            "smtp_port": int(os.getenv("SMTP_PORT", "587")),
            "smtp_username": os.getenv("SMTP_USERNAME", ""),
            "smtp_key": os.getenv("SMTP_KEY", ""),
            "smtp_sender_email": os.getenv("SMTP_SENDER_EMAIL", ""),
            "smtp_use_tls": os.getenv("SMTP_USE_TLS", "true").lower() == "true",
        }

def send_chat_notification(title, message, color="#EA4335", secrets=None):
    """
    Directly post a notification to Google Chat Space via Webhook if configured.
    """
    if secrets is None:
        secrets = __get_notification_secrets()
    webhook_url = secrets.get("google_chat_webhook_url", "").strip()
    if not webhook_url or not webhook_url.startswith("https://chat.googleapis.com/"):
        return
    try:
        payload = {
            "text": f"*{title}*\n\n{message}"
        }
        requests.post(webhook_url, json=payload, timeout=5)
    except Exception:
        pass


def send_email_notification(subject, html_content, secrets=None, extra_emails=None):
    """
    Directly send email notification via configured SMTP server.
    """
    recipients = [e for e in NOTIFICATION_EMAILS if e]
    if extra_emails:
        for em in extra_emails:
            if em and "@" in em and em not in recipients and not em.endswith("gserviceaccount.com"):
                recipients.append(em)

    if not recipients:
        print("[EMAIL] No notification emails configured or found. Skipping direct email.")
        return
    if secrets is None:
        secrets = __get_notification_secrets()

    smtp_host = secrets.get("smtp_host", "").strip()
    if not smtp_host:
        print("[EMAIL] SMTP host not configured in Secret Manager. Skipping direct email.")
        return

    smtp_port = int(secrets.get("smtp_port", 587))
    smtp_user = secrets.get("smtp_username", "").strip()
    smtp_key = (secrets.get("smtp_key") or secrets.get("smtp_password", "")).replace(" ", "").strip()
    sender_email = secrets.get("smtp_sender_email", "").strip() or smtp_user
    use_tls = bool(secrets.get("smtp_use_tls", True))

    try:
        msg = MIMEMultipart("alternative")
        msg["Subject"] = subject
        msg["From"] = sender_email
        msg["To"] = ", ".join(recipients)

        part = MIMEText(html_content, "html")
        msg.attach(part)

        if smtp_port == 465:
            server = smtplib.SMTP_SSL(smtp_host, smtp_port, timeout=15)
        else:
            server = smtplib.SMTP(smtp_host, smtp_port, timeout=15)
            if use_tls:
                server.starttls()

        if smtp_user and smtp_key:
            server.login(smtp_user, smtp_key)

        server.sendmail(sender_email, recipients, msg.as_string())
        server.quit()
        print(f"[EMAIL] Direct email notification sent successfully to: {recipients}")
    except Exception as e:
        print(f"[EMAIL ERROR] Failed to send direct email via SMTP: {e}")

def dispatch_alerts(title, subject, body_text, body_html, extra_emails=None):
    """
    Helper to trigger direct notifications to both Chat and Email using Secret Manager.
    """
    secrets = __get_notification_secrets()
    send_chat_notification(title, body_text, secrets=secrets)
    send_email_notification(subject, body_html, secrets=secrets, extra_emails=extra_emails)

def __get_latest_reattacher_from_logs():
    """
    Query Cloud Logging API with retry/backoff to find who re-attached billing if not in trigger payload.
    """
    if not PROJECT_ID:
        return "Unknown User", ""
    try:
        from google.cloud import logging_v2
        client = logging_v2.Client(project=PROJECT_ID)
        log_filter = (
            'protoPayload.serviceName="cloudbilling.googleapis.com" '
            'AND (protoPayload.methodName:"UpdateProjectBillingInfo" OR protoPayload.methodName:"AssignResourceToBillingAccount") '
            'AND NOT protoPayload.authenticationInfo.principalEmail:"gserviceaccount.com"'
        )
        for attempt in range(3):
            entries = list(client.list_entries(filter_=log_filter, order_by=logging_v2.DESCENDING, page_size=5))
            if entries:
                entry = entries[0]
                payload = entry.payload if isinstance(entry.payload, dict) else {}
                proto = payload.get("protoPayload", payload)
                user = proto.get("authenticationInfo", {}).get("principalEmail", "Unknown User")
                req = proto.get("request", {})
                resp = proto.get("response", {})
                billing_acct = (
                    req.get("projectBillingInfo", {}).get("billingAccountName", "")
                    or req.get("billingAccountName", "")
                    or resp.get("billingAccountName", "")
                    or proto.get("resourceName", "")
                ).replace("billingAccounts/", "")
                if billing_acct:
                    return user, billing_acct
            time.sleep(2)
    except Exception as e:
        print(f"[LOGGING QUERY WARNING] Could not query audit logs: {e}")
    
    # Direct Cloud Billing API fallback
    try:
        billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
        info = billing.projects().getBillingInfo(name=PROJECT_NAME).execute()
        acct = info.get("billingAccountName", "").replace("billingAccounts/", "")
        return "Authorized User", acct
    except Exception as e:
        print(f"[BILLING API WARNING] Could not query current billing info: {e}")
    return "Authorized User", ""

def __send_reattachment_notification(user_email, billing_acct, next_limit):
    """
    Send direct re-attachment email and Google Chat card.
    """
    formatted_limit = f"${next_limit:,.2f}" if isinstance(next_limit, (int, float)) else f"${next_limit}"
    title = f"Billing Re-attached for Project: {PROJECT_ID} (Now next billing limit is {formatted_limit})"
    subject = f"✅ Billing Re-attached: Now next billing limit is {formatted_limit} (Project: {PROJECT_ID})"
    body_text = (
        f"✅ **Billing Account Re-attached**\n\n"
        f"🔔 **Now next billing limit is {formatted_limit}**\n\n"
        f"• Project ID: {PROJECT_ID}\n"
        f"• Re-attached By: {user_email}\n"
        f"• Billing Account: {billing_acct or 'Active'}\n"
        f"• Now next billing limit is: {formatted_limit}\n"
        f"• Status: Active & Operational\n\n"
        f"Billing has been restored for project `{PROJECT_ID}`. All services and resources are active."
    )
    body_html = f"""
    <html>
    <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
        <div style="background-color: #d4edda; border-left: 6px solid #28a745; padding: 15px; margin-bottom: 20px;">
            <h2 style="color: #155724; margin-top: 0;">✅ Billing Account Re-attached</h2>
            <p style="font-size: 16px; margin-bottom: 0;"><strong>Now next billing limit is <span style="color: #155724; font-size: 18px;">{formatted_limit}</span></strong></p>
        </div>
        <table style="border-collapse: collapse; width: 100%; max-width: 600px; margin-bottom: 20px;">
            <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Project ID</td><td style="padding: 8px 12px; border: 1px solid #dee2e6;">{PROJECT_ID}</td></tr>
            <tr><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Re-attached By</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; color: #155724; font-weight: bold;">{user_email}</td></tr>
            <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Billing Account</td><td style="padding: 8px 12px; border: 1px solid #dee2e6;">{billing_acct or 'Active'}</td></tr>
            <tr><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Now next billing limit is</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; color: #28a745; font-weight: bold; font-size: 15px;">{formatted_limit}</td></tr>
            <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Status</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; color: #28a745; font-weight: bold;">Active & Operational</td></tr>
        </table>
        <p>Billing has been restored for project <strong>{PROJECT_ID}</strong>. All services and resources are active.</p>
    </body>
    </html>
    """
    dispatch_alerts(title, subject, body_text, body_html, extra_emails=[user_email])



def get_next_near_limit(curr_limit, budget_limits):
    """
    Finds the next nearest higher threshold strictly above curr_limit from budget_limits.
    If curr_limit is at or above the highest threshold, stays at max(budget_limits).
    If curr_limit is below the lowest threshold, returns min(budget_limits).
    """
    if not budget_limits:
        return curr_limit or 50.0
    sorted_limits = sorted(list(set([float(x) for x in budget_limits if float(x) > 0])))
    if not sorted_limits:
        return curr_limit or 50.0

    higher_limits = [l for l in sorted_limits if l > curr_limit]
    if higher_limits:
        return min(higher_limits)
    return max(sorted_limits)

def reconcile_active_limit(curr_active, budget_limits, cost_amount=None):
    """
    Reconciles active_limit against authoritative budget_limits from Billing Budget Manager.
    Aligns to the next near value covering current spend or closest tier.
    """
    if not budget_limits:
        return curr_active or 50.0
    sorted_limits = sorted(list(set([float(x) for x in budget_limits if float(x) > 0])))
    if not sorted_limits:
        return curr_active or 50.0

    # If current spend exceeds the active limit, advance to the next near ceiling tier that covers spend
    if cost_amount is not None and curr_active is not None and cost_amount > curr_active:
        valid_ceilings = [l for l in sorted_limits if l >= cost_amount]
        if valid_ceilings:
            return min(valid_ceilings)
        return max(sorted_limits)

    if curr_active is not None and curr_active in sorted_limits:
        return curr_active

    if cost_amount is not None and cost_amount > 0:
        valid_ceilings = [l for l in sorted_limits if l >= cost_amount]
        if valid_ceilings:
            return min(valid_ceilings)
        return max(sorted_limits)

    if curr_active is not None:
        higher_or_equal = [l for l in sorted_limits if l >= curr_active]
        if higher_or_equal:
            return min(higher_or_equal)
        return max(sorted_limits)

    return min(sorted_limits)

def __fetch_budgets_from_billing_api():
    """
    Query Cloud Billing Budgets API for all configured budget target amounts for this project.
    """
    try:
        # Find billing account
        billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
        info = billing.projects().getBillingInfo(name=PROJECT_NAME).execute()
        billing_acct = info.get("billingAccountName", "").replace("billingAccounts/", "")
        if not billing_acct:
            return []

        # Query budgets
        budgets_service = discovery.build("billingbudgets", "v1", cache_discovery=False)
        parent = f"billingAccounts/{billing_acct}"
        resp = budgets_service.billingAccounts().budgets().list(parent=parent).execute()
        budgets_list = resp.get("budgets", [])

        discovered_limits = []
        for b in budgets_list:
            bf = b.get("budgetFilter", {})
            projects = bf.get("projects", [])
            # If no project filter, or if this project matches
            if not projects or any(PROJECT_ID in p for p in projects):
                amt = b.get("amount", {}).get("specifiedAmount", {})
                if amt:
                    units = int(amt.get("units", "0"))
                    nanos = int(amt.get("nanos", 0))
                    val = float(units) + (float(nanos) / 1e9)
                    if val > 0:
                        discovered_limits.append(val)
        return sorted(list(set(discovered_limits)))
    except Exception as e:
        print(f"[BUDGET API WARNING] Could not query budgets via REST API: {e}")
        return []

def get_parameter_state(parameter_id):
    """
    Retrieve state directly from Parameter Manager without syncing or overriding limits from Cloud Billing Budgets.
    Parameter Manager serves as the authoritative source of truth.
    """
    state = __get_parameter_payload(parameter_id) or {}
    limits = sorted([float(x) for x in state.get("limits", []) if float(x) > 0])
    if not limits:
        limits = [float(state.get("active_limit", 50.0))]
        state["limits"] = limits

    active_limit = float(state.get("active_limit", limits[0]))
    return limits, active_limit, state

@functions_framework.cloud_event
def stop_billing(cloud_event: CloudEvent):
    # Decode the Pub/Sub message data from the CloudEvent
    try:
        pubsub_message = cloud_event.data.get("message", {})
        base64_data = pubsub_message.get("data", "")
        if not base64_data:
            print("Pub/Sub message contains no data payload.")
            return
        pubsub_data = base64.b64decode(base64_data)
        pubsub_str = pubsub_data.decode("utf-8")
        print(f"Pubsub data is : {pubsub_str}")
    except Exception as e:
        print(f"Failed to decode Pub/Sub message data: {e}")
        return

    try:
        pubsub_json = json.loads(pubsub_str)
    except json.JSONDecodeError as e:
        print(f"Received message is not valid JSON: {e}")
        return

    parameter_id = os.getenv("STATE_PARAMETER_ID", "do-not-delete-billing-state")
    current_month_str = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")

    # =========================================================================
    # CASE 0: Cloud Scheduler Hourly Budget Sync Ping (No-op since syncing is disabled)
    # =========================================================================
    if pubsub_json.get("action") == "sync_budget_state" or pubsub_json.get("source") == "cloud_scheduler":
        print("[SCHEDULER] Periodic sync ping received, but external budget sync is disabled. No changes made.")
        return

    # =========================================================================
    # CASE A: Real-time Cloud Audit Log Trigger for Manual Re-attachment
    # =========================================================================
    if "protoPayload" in pubsub_json:
        proto = pubsub_json.get("protoPayload", {})
        service_name = proto.get("serviceName", "")
        method_name = proto.get("methodName", "")
        principal_email = proto.get("authenticationInfo", {}).get("principalEmail", "")

        if "cloudbilling.googleapis.com" in service_name and ("UpdateProjectBillingInfo" in method_name or "AssignResourceToBillingAccount" in method_name):
            # Ignore service account automated calls
            if "gserviceaccount.com" in principal_email:
                print(f"[AUDIT LOG] Ignoring automated service account action from: {principal_email}")
                return

            req = proto.get("request", {})
            resp = proto.get("response", {})
            billing_acct = (
                req.get("projectBillingInfo", {}).get("billingAccountName", "")
                or req.get("billingAccountName", "")
                or resp.get("billingAccountName", "")
                or proto.get("resourceName", "")
            ).replace("billingAccounts/", "")

            # If billing account is not directly in the log payload, query billing API directly
            if not billing_acct:
                try:
                    billing = discovery.build("cloudbilling", "v1", cache_discovery=False)
                    info = billing.projects().getBillingInfo(name=PROJECT_NAME).execute()
                    if info.get("billingEnabled", False):
                        billing_acct = info.get("billingAccountName", "").replace("billingAccounts/", "")
                except Exception as e:
                    print(f"[AUDIT LOG WARNING] Could not verify billing API: {e}")

            # If billing account is still empty, it was a detachment event
            if not billing_acct:
                print(f"[AUDIT LOG] Detected detachment event by {principal_email}. Skipping reattachment handler.")
                return

            print(f"🎯 [RE-ATTACHMENT AUDIT LOG] Manual billing re-attachment detected! Actor: {principal_email}, Project: {PROJECT_ID}, Account: {billing_acct}")

            budget_limits, curr_active, state = get_parameter_state(parameter_id)
            
            # Check next near values as next limit (if not already stepped up prior to detachment)
            next_limit = curr_active if state.get("status") == "detached" else get_next_near_limit(curr_active, budget_limits)

            # Deduplication: If already active and on this limit, skip redundant reattachment handling
            if state.get("status") == "active" and state.get("active_limit") == next_limit and state.get("last_reattached_by") == principal_email:
                print(f"[RE-ATTACHMENT] Billing is already active at limit {next_limit}. Skipping duplicate reattachment event.")
                return

            state["status"] = "active"
            state["active_limit"] = next_limit
            state["limits"] = budget_limits
            state["month"] = current_month_str
            state["last_reattached_by"] = principal_email
            state.pop("detachment_date", None)
            state.pop("detaching_timestamp", None)
            state.pop("warned_countdown_limit", None)
            state.pop("warned_99_limit", None)
            state.pop("warned_thresholds", None)
            __add_parameter_version(parameter_id, state)
            print(f"[RE-ATTACHMENT] State updated to active in Parameter Manager with limit ({next_limit}): {state}")

            # Send the direct notification strictly once
            __send_reattachment_notification(principal_email, billing_acct, next_limit)
        else:
            print(f"[AUDIT LOG] Non-reattachment audit log event ignored (Service: {service_name}, Method: {method_name}).")
        return

    # =========================================================================
    # CASE B: Standard Cloud Billing Budget Pub/Sub Alert Trigger
    # =========================================================================
    try:
        cost_amount = float(pubsub_json["costAmount"])
        budget_amount = float(pubsub_json["budgetAmount"])
        budget_display_name = pubsub_json.get("budgetDisplayName", "")
        cost_interval_start = pubsub_json.get("costIntervalStart", "")
    except (KeyError, ValueError, TypeError) as e:
        print(f"Received message is neither a valid budget payload nor re-attachment log: {e}")
        return

    # 1. Stale Notification Filter: Drop messages belonging to a previous month/billing cycle
    if cost_interval_start:
        interval_month = cost_interval_start[:7]
        if interval_month < current_month_str:
            print(f"[INFO] Dropping stale budget notification from previous billing period ({interval_month} < {current_month_str}).")
            return

    print(f"Project ID is : {PROJECT_ID}")
    print(f"cost Amount is : {cost_amount}")
    print(f"budgetAmount is : {budget_amount}")
    print(f"budgetDisplayName is : {budget_display_name}")
    print(f"costIntervalStart is : {cost_interval_start}")

    billing = discovery.build(
        "cloudbilling",
        "v1",
        cache_discovery=False,
    )
    projects = billing.projects()
    billing_enabled = __is_billing_enabled(PROJECT_NAME, projects)

    if not billing_enabled:
        print(f"[INFO] Billing is already disabled for project {PROJECT_ID}. Acknowledging message and exiting immediately.")
        return

    # Load thresholds directly from Parameter Manager as authoritative state
    budget_limits, active_limit, state = get_parameter_state(parameter_id)
    state_status = state.get("status", "active")
    state_month = state.get("month", "")

    # Monthly Reset
    if state_month and state_month != current_month_str:
        default_initial_limit = budget_limits[0] if budget_limits else budget_amount
        print(f"[RESET] New month detected ({current_month_str} != {state_month}). Resetting active limit to {default_initial_limit}.")
        state["active_limit"] = default_initial_limit
        state["status"] = "active"
        state["month"] = current_month_str
        state.pop("detachment_date", None)
        state.pop("detaching_timestamp", None)
        state.pop("warned_countdown_limit", None)
        state.pop("warned_99_limit", None)
        state.pop("warned_thresholds", None)
        state.pop("inactive_limit", None)
        state.pop("previous_limit", None)
        __add_parameter_version(parameter_id, state)
        active_limit = default_initial_limit
        state_status = "active"

    # If status was 'detaching', check if detachment is currently in progress
    if state_status == "detaching":
        detaching_time = state.get("detaching_timestamp", 0)
        if time.time() - detaching_time < 600:
            print("[INFO] Billing detachment is already in progress ('detaching'). Skipping duplicate/concurrent trigger.")
            return
        else:
            print("[WARNING] State was 'detaching' for more than 10 minutes without completing. Proceeding with fresh evaluation.")

    print(f"[EVALUATION] Current Cost: {cost_amount}, Active Limit: {active_limit}, Current Status: '{state_status}', Billing Enabled: {billing_enabled}")

    # Fallback Re-attachment Recovery (if Log Sink event was delayed or missed)
    if state_status in ["detached", "detachment_failed"] and billing_enabled:
        print(f"[RECOVERY] Billing is enabled and state was '{state_status}'. Executing fallback re-attachment handler...")
        user_who_attached, b_acct = __get_latest_reattacher_from_logs()
        
        # Use curr_active (already stepped up before detaching) or calculate next near limit
        next_limit = active_limit if state_status == "detached" else get_next_near_limit(active_limit, budget_limits)

        # If already active and on this limit, do not re-send
        if state.get("status") == "active" and state.get("active_limit") == next_limit and state.get("last_reattached_by") == user_who_attached:
            print(f"[RECOVERY] Billing is already active at limit {next_limit}. Skipping redundant alert.")
        else:
            state["active_limit"] = next_limit
            state["status"] = "active"
            state["limits"] = budget_limits
            state["month"] = current_month_str
            state["last_reattached_by"] = user_who_attached
            state.pop("detachment_date", None)
            state.pop("detaching_timestamp", None)
            state.pop("warned_countdown_limit", None)
            state.pop("warned_99_limit", None)
            state.pop("warned_thresholds", None)
            __add_parameter_version(parameter_id, state)

            active_limit = next_limit
            state_status = "active"

            # Strictly send the alert once
            __send_reattachment_notification(user_who_attached, b_acct, next_limit)
            print(f"[RECOVERY COMPLETE] Re-attachment alert sent directly from Cloud Run.")


    # 1. Under 99% of active limit -> Check intermediate threshold alerts (e.g. 50%, 75%, 90%, 95%)
    if cost_amount < (0.99 * active_limit):
        STANDARD_THRESHOLDS = [0.50, 0.75, 0.90, 0.95]
        warned_thresholds = [float(x) for x in state.get("warned_thresholds", [])]
        
        # Identify newly crossed thresholds
        unwarned = [t for t in STANDARD_THRESHOLDS if cost_amount >= (t * active_limit) and t not in warned_thresholds]
        
        if unwarned:
            highest_t = max(unwarned)
            pct_label = f"{int(round(highest_t * 100))}%"
            formatted_spend = f"${cost_amount:,.2f}"
            formatted_limit = f"${active_limit:,.2f}"

            title = f"⚠️ Budget Alert: Spend at {pct_label} for Project {PROJECT_ID}"
            subject = f"⚠️ Budget Alert: Spend reached {pct_label} ({formatted_spend}/{formatted_limit}) for project {PROJECT_ID}"
            body_text = (
                f"⚠️ **Budget Threshold Alert ({pct_label} reached)**\n\n"
                f"• Project ID: {PROJECT_ID}\n"
                f"• Current Spend: {formatted_spend}\n"
                f"• Active Limit: {formatted_limit}\n"
                f"• Threshold: {pct_label}\n"
                f"• Status: Active & Operational\n\n"
                f"Spending has reached {pct_label} of the active budget limit ({formatted_limit})."
            )
            body_html = f"""
            <html>
            <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
                <div style="background-color: #fff3cd; border-left: 6px solid #ffc107; padding: 15px; margin-bottom: 20px;">
                    <h2 style="color: #856404; margin-top: 0;">⚠️ Budget Threshold Alert ({pct_label} Reached)</h2>
                    <p>Project <strong>{PROJECT_ID}</strong> has reached <strong>{pct_label}</strong> of its active budget limit.</p>
                </div>
                <table style="border-collapse: collapse; width: 100%; max-width: 600px; margin-bottom: 20px;">
                    <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Project ID</td><td style="padding: 8px 12px; border: 1px solid #dee2e6;">{PROJECT_ID}</td></tr>
                    <tr><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Current Spend</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; color: #856404; font-weight: bold;">{formatted_spend}</td></tr>
                    <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Active Limit</td><td style="padding: 8px 12px; border: 1px solid #dee2e6;">{formatted_limit}</td></tr>
                    <tr><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Threshold Reached</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold; color: #856404;">{pct_label}</td></tr>
                    <tr style="background-color: #f8f9fa;"><td style="padding: 8px 12px; border: 1px solid #dee2e6; font-weight: bold;">Status</td><td style="padding: 8px 12px; border: 1px solid #dee2e6; color: #28a745; font-weight: bold;">Active & Operational</td></tr>
                </table>
                <p>Billing is active. This is an informational budget alert.</p>
            </body>
            </html>
            """
            dispatch_alerts(title, subject, body_text, body_html)
            
            all_crossed = sorted(list(set(warned_thresholds + [t for t in STANDARD_THRESHOLDS if cost_amount >= (t * active_limit)])))
            state["warned_thresholds"] = all_crossed
            __add_parameter_version(parameter_id, state)
            print(f"[THRESHOLD ALERT] Sent {pct_label} threshold alert for cost {formatted_spend} / {formatted_limit}. Updated warned_thresholds: {all_crossed}")
        else:
            print(f"[INFO] Spend ({cost_amount}) is below 99% of active limit ({active_limit}) and no new thresholds crossed. No detachment needed.")
        return

    # 2. Between 99% and 100% of active limit -> Direct warning without detaching billing
    if cost_amount >= (0.99 * active_limit) and cost_amount <= active_limit:
        if state.get("warned_99_limit") == active_limit:
            print(f"[INFO] 99% warning already sent for limit {active_limit}. Skipping duplicate alert.")
            return

        title = f"⚠️ Budget Warning: Spend at 99%+ for Project {PROJECT_ID}"
        subject = f"⚠️ Budget Warning: Spend at 99%+ of active limit for project {PROJECT_ID}"
        body_text = (
            f"⚠️ **Budget Limit Warning (99%+ reached)**\n\n"
            f"• Project ID: {PROJECT_ID}\n"
            f"• Current Spend: {cost_amount}\n"
            f"• Active Limit: {active_limit}\n\n"
            f"Spending is approaching the active limit threshold. Billing will be detached if spending exceeds {active_limit}."
        )
        body_html = f"""
        <html>
        <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
            <div style="background-color: #fff3cd; border-left: 6px solid #ffc107; padding: 15px; margin-bottom: 20px;">
                <h2 style="color: #856404; margin-top: 0;">⚠️ Budget Threshold Warning (99% reached)</h2>
                <p>Project <strong>{PROJECT_ID}</strong> has reached 99%+ of its active budget limit.</p>
            </div>
            <ul>
                <li><strong>Project ID:</strong> {PROJECT_ID}</li>
                <li><strong>Current Spend:</strong> {cost_amount}</li>
                <li><strong>Active Limit:</strong> {active_limit}</li>
            </ul>
            <p>Billing is still active, but if spending continues to exceed 100% ({active_limit}), billing will get detached soon.</p>
        </body>
        </html>
        """
        dispatch_alerts(title, subject, body_text, body_html)
        state["warned_99_limit"] = active_limit
        __add_parameter_version(parameter_id, state)
        print(f"[INFO] Cost ({cost_amount}) reached 99.1%+ threshold but is still <= active limit ({active_limit}). Direct warning sent to Chat/Email; billing will NOT be detached yet.")
        return

    # 3. Strictly exceeds 100% of active limit -> Emit warning, send direct warning & proceed to detach billing
    if state_status == "detached" and not billing_enabled:
        print(f"[INFO] Billing is already marked as detached for limit: {active_limit} and billing is disabled. Skipping duplicate detachment.")
        return

    if state.get("warned_countdown_limit") == active_limit:
        print(f"[INFO] Countdown alert already sent for limit {active_limit}. Detachment in progress or completed. Skipping duplicate alert.")
        return

    if not PROJECT_ID:
        print("[ERROR] No project specified in GCP_PROJECT environment variable. Aborting.")
        return

    # Lock the state before sleeping
    state["status"] = "detaching"
    state["detaching_timestamp"] = int(time.time())
    state["warned_countdown_limit"] = active_limit
    __add_parameter_version(parameter_id, state)
    print(f"[LOCK] Locked state as 'detaching' in Parameter Manager: {state}")

    # FIRE WARNING ALERT DIRECTLY FROM CLOUD RUN (Sent strictly ONCE)
    countdown_title = f"Billing Will Get Detached Soon for Project: {PROJECT_ID}"
    countdown_subject = f"🚨 URGENT: Billing Will Get Detached Soon for Project: {PROJECT_ID}"
    countdown_text = (
        f"🚨 **URGENT: Billing Will Get Detached Soon**\n\n"
        f"• Project ID: {PROJECT_ID}\n"
        f"• Current Spend: {cost_amount}\n"
        f"• Active Limit: {active_limit}\n"
        f"• Status: Billing will get detached soon\n\n"
        f"Project spend has exceeded the 100% active budget limit. Billing for project `{PROJECT_ID}` will get detached soon."
    )
    countdown_html = f"""
    <html>
    <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
        <div style="background-color: #f8d7da; border-left: 6px solid #dc3545; padding: 15px; margin-bottom: 20px;">
            <h2 style="color: #721c24; margin-top: 0;">🚨 URGENT: Billing Will Get Detached Soon</h2>
            <p>Project: <strong>{PROJECT_ID}</strong> has exceeded 100% of its active budget limit.</p>
        </div>
        <ul>
            <li><strong>Project ID:</strong> {PROJECT_ID}</li>
            <li><strong>Current Spend:</strong> {cost_amount}</li>
            <li><strong>Active Limit:</strong> {active_limit}</li>
            <li><strong>Status:</strong> ⏳ Billing will get detached soon</li>
        </ul>
        <p style="color: #dc3545; font-weight: bold;">Billing will get detached soon unless project limits are updated.</p>
    </body>
    </html>
    """
    dispatch_alerts(countdown_title, countdown_subject, countdown_text, countdown_html)

    # Delay before detaching billing to allow any final operations
    try:
        print("[ACTION] Waiting 5 minutes before detaching billing...")
        time.sleep(300)
    except Exception as e:
        print(f"[WARNING] Sleep interrupted: {e}")

    # Re-evaluate latest Parameter Manager state in case an engineer intervened during the 5-minute grace period
    latest_state = __get_parameter_payload(parameter_id) or state
    latest_active_limit = float(latest_state.get("active_limit", active_limit))
    latest_status = latest_state.get("status", "detaching")

    if latest_active_limit > active_limit and cost_amount <= latest_active_limit:
        print(f"🛑 [ABORT DETACHMENT] Detected limit increase during grace period (from {active_limit} to {latest_active_limit}). Current cost ({cost_amount}) is within new limit. Detachment aborted.")
        latest_state["status"] = "active"
        latest_state.pop("detaching_timestamp", None)
        latest_state.pop("warned_countdown_limit", None)
        latest_state.pop("warned_99_limit", None)
        latest_state.pop("warned_thresholds", None)
        __add_parameter_version(parameter_id, latest_state)
        return

    if latest_status == "active":
        print(f"🛑 [ABORT DETACHMENT] State was manually reset to 'active' during grace period. Detachment aborted.")
        return

    # Check if billing is still enabled before attempting to disable
    billing_enabled_now = __is_billing_enabled(PROJECT_NAME, projects)
    if billing_enabled_now:
        print(f"[ACTION] Billing is enabled. Proceeding to disable billing for {PROJECT_NAME}...")
        __disable_billing_for_project(PROJECT_NAME, projects, parameter_id, latest_state, budget_limits, cost_amount, latest_active_limit)
    else:
        print("[INFO] Billing is already disabled. Skipping detachment.")

def __is_billing_enabled(project_name, projects):
    """
    Check if billing is enabled for the project
    """
    print(f"[DEBUG] Executing __is_billing_enabled for {project_name}")
    try:
        res = projects.getBillingInfo(name=project_name).execute()
        enabled = res.get("billingEnabled", False)
        print(f"[DEBUG] Billing status response for {project_name}: billingEnabled={enabled}")
        return enabled
    except Exception as e:
        print(f"[WARNING] Unable to determine if billing is enabled (Error: {e}); assuming billing is enabled.")
        return True

def __disable_billing_for_project(project_name, projects, parameter_id=None, state=None, budget_limits=None, cost_amount=None, active_limit=None):
    """
    Disable billing by removing the billing account.
    Updates Parameter Manager BEFORE detaching, setting the breached threshold as inactive
    and advancing active_limit to the next budget limit threshold.
    """
    # 1. Update Parameter Manager BEFORE detaching
    if parameter_id and state:
        curr_breached_limit = float(active_limit) if active_limit is not None else float(state.get("active_limit", 50.0))
        next_limit = get_next_near_limit(curr_breached_limit, budget_limits) if budget_limits else curr_breached_limit

        state["previous_limit"] = curr_breached_limit
        state["inactive_limit"] = curr_breached_limit
        state["active_limit"] = next_limit
        state["status"] = "detached"
        state["detachment_date"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
        state.pop("detaching_timestamp", None)
        state.pop("warned_countdown_limit", None)
        state.pop("warned_99_limit", None)
        state.pop("warned_thresholds", None)

        print(f"[STATE UPDATE BEFORE DETACH] Updating Parameter Manager before detachment: inactive_limit={curr_breached_limit}, next active_limit={next_limit}: {state}")
        __add_parameter_version(parameter_id, state)

    # 2. Proceed with detaching billing
    print(f"[ACTION] Executing __disable_billing_for_project for {project_name}")
    body = {"billingAccountName": ""}
    try:
        res = projects.updateBillingInfo(name=project_name, body=body).execute()
        print(f"ALERT: Billing has been successfully detached for project {PROJECT_ID}. Billing account removed. API response: {json.dumps(res)}")

        # Send direct Final Detachment Alert to Google Chat and Email
        detached_title = f"Billing Detached for Project: {PROJECT_ID}"
        detached_subject = f"🚨 Billing Detached for Project: {PROJECT_ID}"
        detached_text = (
            f"🚨 **Project Billing Detached**\n\n"
            f"Billing for project `{PROJECT_ID}` has been automatically disabled because spending reached/exceeded the configured limit.\n\n"
            f"• Project ID: {PROJECT_ID}\n"
            f"• Actual Cost: {cost_amount}\n"
            f"• Inactive (Breached) Limit: {active_limit}\n"
            f"• Next Active Limit: {state.get('active_limit', active_limit) if state else active_limit}\n"
            f"• Status: Detached (Services Disabled)\n\n"
            f"**To Restore Services:**\n"
            f"1. Billing admin login to Google Cloud Console. If you are not billing admin contact/take help from billing admin.\n"
            f"2. Navigate to Billing -> My Projects.\n"
            f"3. Locate project '{PROJECT_ID}', click the three dots, and select 'Change Billing'.\n"
            f"4. Select your Billing Account and click 'Set Account'."
        )
        detached_html = f"""
        <html>
        <body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333;">
            <div style="background-color: #f8d7da; border-left: 6px solid #dc3545; padding: 15px; margin-bottom: 20px;">
                <h2 style="color: #721c24; margin-top: 0;">🚨 Action Required: Project Billing Detached</h2>
                <p>Billing for project <strong>{PROJECT_ID}</strong> has been automatically disabled.</p>
            </div>
            <ul>
                <li><strong>Project ID:</strong> {PROJECT_ID}</li>
                <li><strong>Actual Cost:</strong> {cost_amount}</li>
                <li><strong>Inactive (Breached) Limit:</strong> {active_limit}</li>
                <li><strong>Next Active Limit:</strong> {state.get('active_limit', active_limit) if state else active_limit}</li>
                <li><strong>Status:</strong> <span style="color: #dc3545; font-weight: bold;">Detached (Billing Disabled)</span></li>
            </ul>
            <hr style="border: 0; border-top: 1px solid #ccc; margin: 20px 0;">
            <h3>🔧 Steps to Re-attach Billing</h3>
            <ol>
                <li>Billing admin login to <strong>Google Cloud Console</strong>. If you are not billing admin contact/take help from billing admin.</li>
                <li>Navigate to <strong>Billing</strong> &gt; <strong>My Projects</strong>.</li>
                <li>Locate project <strong>{PROJECT_ID}</strong>, click the three dots, and select <strong>Change Billing</strong>.</li>
                <li>Select your Billing Account and click <strong>Set Account</strong>.</li>
            </ol>
        </body>
        </html>
        """
        dispatch_alerts(detached_title, detached_subject, detached_text, detached_html)
    except Exception as e:
        print(f"[CRITICAL ERROR] Failed to disable billing; check IAM permissions for service account. Error: {e}")
        # When detachment fails, record detachment_failed in Parameter Manager
        if parameter_id and state:
            state["status"] = "detachment_failed"
            __add_parameter_version(parameter_id, state)
            print(f"[STATE ERROR] Updated billing state to 'detachment_failed': {state}")

def __get_parameter_payload(parameter_id):
    print(f"[DEBUG] Fetching payload for parameter '{parameter_id}' in project '{PROJECT_ID}'...")
    try:
        from google.cloud import parametermanager_v1
        client = parametermanager_v1.ParameterManagerClient()
        parent = f"projects/{PROJECT_ID}/locations/global/parameters/{parameter_id}"
        
        # In Parameter Manager, 'latest' is not a virtual alias; we must discover the highest version ID
        req = parametermanager_v1.ListParameterVersionsRequest(parent=parent)
        pager = client.list_parameter_versions(request=req)
        numeric_versions = []
        for v in pager:
            v_id = v.name.split("/")[-1]
            if v_id.isdigit():
                numeric_versions.append(int(v_id))
        
        if not numeric_versions:
            print(f"[WARNING] No numeric parameter versions found for '{parameter_id}'.")
            return None
            
        latest_version_id = str(max(numeric_versions))
        name = f"{parent}/versions/{latest_version_id}"
        request = parametermanager_v1.RenderParameterVersionRequest(name=name)
        response = client.render_parameter_version(request=request)
        payload = response.rendered_payload.decode("UTF-8")
        parsed_payload = json.loads(payload)
        print(f"[DEBUG] Successfully retrieved parameter payload from version {latest_version_id}: {parsed_payload}")
        return parsed_payload
    except Exception as e:
        print(f"[ERROR] Error accessing parameter version for '{parameter_id}': {e}")
        return None


def __add_parameter_version(parameter_id, state):
    try:
        from google.cloud import parametermanager_v1
        client = parametermanager_v1.ParameterManagerClient()
        parent = f"projects/{PROJECT_ID}/locations/global/parameters/{parameter_id}"
        
        # 1. List existing versions
        existing_versions = []
        try:
            req = parametermanager_v1.ListParameterVersionsRequest(parent=parent)
            pager = client.list_parameter_versions(request=req)
            for v in pager:
                version_id = v.name.split("/")[-1]
                existing_versions.append(version_id)
        except Exception as e:
            print(f"[PARAMETER MANAGER WARNING] Error listing parameter versions: {e}")
            
        # Parse version numbers to find highest numeric version
        numeric_versions = []
        for v in existing_versions:
            try:
                numeric_versions.append(int(v))
            except ValueError:
                pass
                
        if numeric_versions:
            next_version_num = max(numeric_versions) + 1
            next_version_id = str(next_version_num)
        elif existing_versions:
            next_version_id = f"v{int(time.time())}"
        else:
            # Fallback to timestamp to guarantee uniqueness and prevent 409 collision with version '1'
            next_version_id = f"{int(time.time())}"
        
        # 2. Create the new version
        payload = json.dumps(state)
        parameter_version = parametermanager_v1.ParameterVersion(
            payload=parametermanager_v1.ParameterVersionPayload(data=payload.encode("utf-8"))
        )
        request = parametermanager_v1.CreateParameterVersionRequest(
            parent=parent,
            parameter_version_id=next_version_id,
            parameter_version=parameter_version
        )
        response = client.create_parameter_version(request=request)
        print(f"[PARAMETER MANAGER] Added new parameter version '{next_version_id}': {response.name}")
        
        # 3. Prune old versions to keep only the 3 latest ones
        if numeric_versions:
            if next_version_id.isdigit():
                numeric_versions.append(int(next_version_id))
            numeric_versions.sort()
            if len(numeric_versions) > 3:
                versions_to_delete = numeric_versions[:-3] # keep only the last 3
                for v_num in versions_to_delete:
                    v_name = f"{parent}/versions/{v_num}"
                    try:
                        del_req = parametermanager_v1.DeleteParameterVersionRequest(name=v_name)
                        client.delete_parameter_version(request=del_req)
                        print(f"[PARAMETER MANAGER] Deleted old parameter version: {v_name}")
                    except Exception as e:
                        print(f"[PARAMETER MANAGER WARNING] Could not delete old parameter version {v_name}: {e}")
                        
    except Exception as e:
        print(f"[PARAMETER MANAGER ERROR] Error adding parameter version: {e}")
