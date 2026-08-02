export class ClipSerialQueue {
  constructor() {
    this.tail = Promise.resolve();
  }

  enqueue(operation) {
    const result = this.tail.then(operation);
    // A rejected operation is still returned to its caller, but must not poison
    // later work queued on the same ordered transport.
    this.tail = result.catch(() => undefined);
    return result;
  }
}
