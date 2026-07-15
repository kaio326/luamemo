"""Sample Python module for the multi-language parser test."""
import os
from collections import OrderedDict, defaultdict

CONSTANT = 42


class Animal:
    """An animal that can speak."""

    def __init__(self, name):
        self.name = name

    def speak(self):
        return "..."

    def _private_helper(self):
        return None


class Dog(Animal):
    def speak(self):
        return "woof"


def make_dog(name):
    """Create a dog with the given name."""
    return Dog(name)


async def fetch_all(urls, *, timeout=30):
    return []
