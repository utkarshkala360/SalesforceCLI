import { LightningElement } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { subscribe, unsubscribe, onError } from "lightning/empApi";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import USER_ID from "@salesforce/user/Id";
import FlowModal from "c/flowModal";

const MAX_RECENT = 5;
const MAX_RETRIES = 8;

// TEMPORARY: shows toasts for each step so the popup can be debugged without dev tools
const DEBUG = false;

export default class FlowLauncher extends NavigationMixin(LightningElement) {
  channel = "/event/Open_Screen_Flow__e";
  subscription;
  status = "connecting";
  errorMessage;
  recent = [];
  retries = 0;
  reconnectTimer;
  lastReplayId;
  seenReplayIds = new Set();
  disconnected = false;

  get isConnected() {
    return this.status === "connected";
  }
  get isConnecting() {
    return this.status === "connecting";
  }
  get hasError() {
    return this.status === "error";
  }
  get hasRecent() {
    return this.recent.length > 0;
  }

  connectedCallback() {
    this.debug("info", "Call popup: listener loaded, subscribing...");
    // empApi drops the streaming connection on network blips, laptop sleep or
    // session refresh ("403::Unknown client"); resubscribe instead of giving up.
    onError((err) => {
      console.error("empApi error", JSON.stringify(err));
      this.debug(
        "error",
        "Call popup: connection error " + JSON.stringify(err)
      );
      this.scheduleReconnect();
    });
    this.connect();
  }

  connect() {
    // after a drop, replay from the last event seen so calls logged meanwhile still pop up
    const replayId = this.lastReplayId != null ? this.lastReplayId : -1;
    subscribe(this.channel, replayId, (msg) => this.handleEvent(msg))
      .then((sub) => {
        this.subscription = sub;
        this.status = "connected";
        this.retries = 0;
        this.debug(
          "success",
          "Call popup: listening for calls (user " + USER_ID + ")"
        );
      })
      .catch((err) => {
        this.debug(
          "error",
          "Call popup: subscribe failed " + JSON.stringify(err)
        );
        this.scheduleReconnect();
      });
  }

  scheduleReconnect() {
    if (this.disconnected || this.reconnectTimer) return;
    if (this.retries >= MAX_RETRIES) {
      this.status = "error";
      this.errorMessage =
        "Lost connection to call events. Refresh the page to reconnect.";
      return;
    }
    this.status = "connecting";
    const delay = Math.min(30000, 1000 * 2 ** this.retries);
    this.retries++;
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      const old = this.subscription;
      this.subscription = null;
      Promise.resolve(old ? unsubscribe(old) : null)
        .catch(() => {})
        .finally(() => this.connect());
    }, delay);
  }

  handleRetry() {
    this.retries = 0;
    this.scheduleReconnect();
  }

  debug(variant, message) {
    console.log("[flowLauncher] " + message);
    if (!DEBUG) return;
    this.dispatchEvent(
      new ShowToastEvent({ title: message, variant, mode: "sticky" })
    );
  }

  disconnectedCallback() {
    this.disconnected = true;
    clearTimeout(this.reconnectTimer);
    if (this.subscription) unsubscribe(this.subscription);
  }

  async handleEvent(msg) {
    const p = msg.data.payload;
    const replayId = msg.data.event && msg.data.event.replayId;
    if (replayId != null) {
      if (this.seenReplayIds.has(replayId)) return; // already handled before a reconnect
      this.seenReplayIds.add(replayId);
      this.lastReplayId = replayId;
    }
    this.debug(
      "info",
      "Call popup: event received for " +
        p.Target_User_Id__c +
        ", flow " +
        p.Flow_Api_Name__c
    );
    // compare 15-char prefixes so 15- and 18-char Ids both match
    if (
      !p.Target_User_Id__c ||
      p.Target_User_Id__c.substring(0, 15) !== USER_ID.substring(0, 15)
    )
      return; // not for this agent

    const entry = {
      key: p.Record_Id__c + "-" + Date.now(),
      recordId: p.Record_Id__c,
      taskId: p.Task_Id__c,
      flowApiName: p.Flow_Api_Name__c,
      receivedAt: new Date().toLocaleTimeString()
    };
    this.recent = [entry, ...this.recent].slice(0, MAX_RECENT);

    try {
      await this.openFlow(entry.flowApiName, entry.recordId, entry.taskId);
    } catch (e) {
      this.debug(
        "error",
        "Call popup: could not open modal " +
          (e && e.message ? e.message : JSON.stringify(e))
      );
    }
  }

  handleReopen(event) {
    const entry = this.recent.find((r) => r.key === event.target.dataset.key);
    if (entry) this.openFlow(entry.flowApiName, entry.recordId, entry.taskId);
  }

  openFlow(flowApiName, recordId, taskId) {
    const inputVariables = [
      { name: "recordId", type: "String", value: recordId }
    ];
    // the call log Task created by CallAnchorWebService
    if (taskId)
      inputVariables.push({ name: "taskId", type: "String", value: taskId });

    // Load the caller's record (the matched Opportunity) behind the popup,
    // so it is already open when the agent closes the modal
    if (recordId) {
      this[NavigationMixin.Navigate]({
        type: "standard__recordPage",
        attributes: { recordId, actionName: "view" }
      });
    }

    return FlowModal.open({
      size: "medium",
      flowApiName,
      recordId,
      taskId,
      inputVariables
    });
  }
}
