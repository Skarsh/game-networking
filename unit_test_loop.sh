#!/bin/bash

while odin test protocol; do
    echo "Test passed, running again..."
done

echo "Test failed!"

