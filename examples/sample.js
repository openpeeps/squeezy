// Sample JavaScript for Squeezy bundler demo
function greet(name) {
  const greeting = "Hello, " + name + "!";
  console.log(greeting);
  return greeting;
}

import { formatDate } from './utils.js';

class App {
  constructor(title) {
    this.title = title;
    this.items = [];
  }

  addItem(item) {
    this.items.push(item);
  }

  render() {
    const header = document.createElement('h1');
    header.textContent = this.title;
    document.body.appendChild(header);

    const list = document.createElement('ul');
    for (var i = 0; i < this.items.length; i++) {
      const li = document.createElement('li');
      li.textContent = this.items[i];
      list.appendChild(li);
    }
    document.body.appendChild(list);

    return this.items.length;
  }
}

/* Export for external use */
export { greet, App };
