import { Controller } from "@hotwired/stimulus"

// Keeps the "Mark all" button in sync with the status broadcast by
// CompleteAllTodoItemsJob, and reloads the items frame when it finishes.
export default class extends Controller {
  static targets = ["button", "status", "frame"]

  submitStart() {
    this.buttonTarget.disabled = true
    this.finishedSinceSubmit = false
  }

  // Turbo re-enables the submitter once the request finishes. Keep it disabled
  // while the enqueued job runs, unless its "done" broadcast already arrived.
  submitEnd(event) {
    const accepted = event.detail.fetchResponse?.statusCode === 202

    this.buttonTarget.disabled = (accepted && !this.finishedSinceSubmit) || this.state === "running"
  }

  statusTargetConnected(element) {
    this.state = element.dataset.state
    this.buttonTarget.disabled = this.state === "running"

    if (this.state !== "running") this.finishedSinceSubmit = true

    if (this.state === "done" && this.hasFrameTarget) {
      // Reload the current page of items (pagination links advance the URL).
      this.frameTarget.src = window.location.href
    }
  }
}
