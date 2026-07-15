import React from 'react';
import { useState } from 'react';
const fs = require('fs');

// Adds two numbers together.
export function add(a, b) {
  return a + b;
}

/** Multiplies two numbers. */
export const multiply = (a, b) => a * b;

class Calculator {
  constructor(initial) {
    this.total = initial;
  }

  add(n) {
    this.total += n;
    return this.total;
  }

  async reset() {
    this.total = 0;
  }
}

export default Calculator;
