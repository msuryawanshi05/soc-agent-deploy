import ipaddress
"""
Security Module - TLS/SSL and Authentication
Handles encryption and authentication for SOC platform
"""

import ssl
import socket
import hashlib
import secrets
import jwt
import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Optional, Tuple
from cryptography import x509
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.backends import default_backend
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
import base64
import os

class CertificateManager:
    """Manages TLS certificates for secure communication"""
    
    @staticmethod
    def generate_self_signed_cert(cert_dir: Path, days_valid: int = 365):
        """Generate self-signed certificate for TLS"""
        cert_dir.mkdir(parents=True, exist_ok=True)
        
        # Generate private key
        private_key = rsa.generate_private_key(
            public_exponent=65537,
            key_size=2048,
            backend=default_backend()
        )
        
        # Save private key
        key_file = cert_dir / "server.key"
        with open(key_file, "wb") as f:
            f.write(private_key.private_bytes(
                encoding=serialization.Encoding.PEM,
                format=serialization.PrivateFormat.TraditionalOpenSSL,
                encryption_algorithm=serialization.NoEncryption()
            ))
        
        # Generate certificate
        subject = issuer = x509.Name([
            x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "State"),
            x509.NameAttribute(NameOID.LOCALITY_NAME, "City"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, "SOC Platform"),
            x509.NameAttribute(NameOID.COMMON_NAME, "SOC Manager"),
        ])
        
        cert = x509.CertificateBuilder().subject_name(
            subject
        ).issuer_name(
            issuer
        ).public_key(
            private_key.public_key()
        ).serial_number(
            x509.random_serial_number()
        ).not_valid_before(
            datetime.now(timezone.utc)
        ).not_valid_after(
            datetime.now(timezone.utc) + timedelta(days=days_valid)
        ).add_extension(
            x509.SubjectAlternativeName([
                x509.DNSName("localhost"),
                x509.DNSName("*.local"),
                x509.IPAddress(ipaddress.IPv4Address("127.0.0.1")),
            ]),
            critical=False,
        ).add_extension(
            x509.ExtendedKeyUsage([
                ExtendedKeyUsageOID.SERVER_AUTH,
                ExtendedKeyUsageOID.CLIENT_AUTH,
            ]),
            critical=False,
        ).sign(private_key, hashes.SHA256(), default_backend())
        
        # Save certificate
        cert_file = cert_dir / "server.crt"
        with open(cert_file, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        
        # For self-signed, CA is same as cert
        ca_file = cert_dir / "ca.crt"
        with open(ca_file, "wb") as f:
            f.write(cert.public_bytes(serialization.Encoding.PEM))
        
        return str(cert_file), str(key_file), str(ca_file)

class TokenAuth:
    """Token-based authentication for agents"""
    
    def __init__(self, secret_key: str):
        self.secret_key = secret_key
    
    def generate_token(self, agent_id: str, expires_hours: int = 24*365) -> str:
        """Generate JWT token for agent authentication"""
        payload = {
            "agent_id": agent_id,
            "exp": datetime.now(timezone.utc) + timedelta(hours=expires_hours),
            "iat": datetime.now(timezone.utc)
        }
        return jwt.encode(payload, self.secret_key, algorithm="HS256")
    
    def verify_token(self, token: str) -> Optional[str]:
        """Verify JWT token and return agent_id if valid"""
        try:
            payload = jwt.decode(token, self.secret_key, algorithms=["HS256"])
            return payload.get("agent_id")
        except jwt.ExpiredSignatureError:
            return None
        except jwt.InvalidTokenError:
            return None

class FieldEncryption:
    """Encrypt sensitive fields in database using AES-256"""
    
    def __init__(self, key: str):
        self.key = hashlib.sha256(key.encode()).digest()
    
    def encrypt(self, plaintext: str) -> str:
        if not plaintext:
            return ""
        iv = os.urandom(16)
        padded = self._pad(plaintext.encode())
        cipher = Cipher(algorithms.AES(self.key), modes.CBC(iv), backend=default_backend())
        encryptor = cipher.encryptor()
        ciphertext = encryptor.update(padded) + encryptor.finalize()
        return base64.b64encode(iv + ciphertext).decode()
    
    def decrypt(self, ciphertext: str) -> str:
        if not ciphertext:
            return ""
        try:
            data = base64.b64decode(ciphertext)
            iv = data[:16]
            encrypted = data[16:]
            cipher = Cipher(algorithms.AES(self.key), modes.CBC(iv), backend=default_backend())
            decryptor = cipher.decryptor()
            padded = decryptor.update(encrypted) + decryptor.finalize()
            return self._unpad(padded).decode()
        except Exception as e:
            return ciphertext
    
    @staticmethod
    def _pad(data: bytes) -> bytes:
        padding_length = 16 - (len(data) % 16)
        return data + bytes([padding_length] * padding_length)
    
    @staticmethod
    def _unpad(data: bytes) -> bytes:
        padding_length = data[-1]
        return data[:-padding_length]

class SecureSocket:
    """Wrapper for TLS socket operations"""
    
    @staticmethod
    def create_server_socket(host: str, port: int, cert_file: str, key_file: str) -> ssl.SSLSocket:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert_file, key_file)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind((host, port))
        sock.listen(5)
        return context.wrap_socket(sock, server_side=True)
    
    @staticmethod
    def create_client_socket(host: str, port: int, ca_file: Optional[str] = None) -> ssl.SSLSocket:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        if ca_file:
            context.load_verify_locations(ca_file)
        else:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        sock = socket.create_connection((host, port))
        return context.wrap_socket(sock, server_hostname=host)

def hash_password(password: str) -> str:
    salt = secrets.token_hex(16)
    pwdhash = hashlib.sha256((password + salt).encode()).hexdigest()
    return f"{salt}${pwdhash}"

def verify_password(password: str, stored_hash: str) -> bool:
    try:
        salt, pwdhash = stored_hash.split('$')
        check_hash = hashlib.sha256((password + salt).encode()).hexdigest()
        return check_hash == pwdhash
    except Exception as e:
        return False
