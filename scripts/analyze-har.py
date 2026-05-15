#!/usr/bin/env python3
import json
import sys
from collections import Counter
from urllib.parse import urlparse

def analyze_har(file_path):
    try:
        with open(file_path, 'r', encoding='utf-8') as f:
            har_data = json.load(f)
    except Exception as e:
        print(f"Error reading HAR file: {e}")
        return

    entries = har_data.get('log', {}).get('entries', [])
    total_requests = len(entries)
    
    # Track stats
    endpoints = []
    total_size = 0
    status_codes = Counter()
    redundant_check = Counter()

    for entry in entries:
        request = entry.get('request', {})
        response = entry.get('response', {})
        url = request.get('url', '')
        method = request.get('method', '')
        status = response.get('status', 0)
        
        parsed_url = urlparse(url)
        path = parsed_url.path
        
        # We focus on API and unique paths
        endpoints.append((method, path))
        
        # Redundancy check (exact URL + Method)
        redundant_check[(method, url)] += 1
        
        # Size
        size = response.get('content', {}).get('size', 0)
        if size < 0: size = 0
        total_size += size
        
        status_codes[status] += 1

    # Frequency analysis
    freq_counter = Counter(endpoints)
    
    print(f"--- HAR Analysis Report ---")
    print(f"Total Requests: {total_requests}")
    print(f"Total Data Transferred: {total_size / 1024 / 1024:.2f} MB")
    print(f"
Top 10 Most Frequent Requests:")
    for (method, path), count in freq_counter.most_common(10):
        print(f"  [{method}] {path}: {count} times")

    print(f"
Potentially Redundant (Exact URL repeated):")
    for (method, url), count in redundant_check.most_common():
        if count > 1:
            print(f"  {count}x [{method}] {url}")

    print(f"
Status Codes:")
    for status, count in status_codes.items():
        print(f"  {status}: {count}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: analyze-har.py <path_to_har_file>")
        sys.exit(1)
    analyze_har(sys.argv[1])
