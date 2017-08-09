using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace hashdehash
{
    public static class hashdehash
    {

    public static string Encrypt(string plainMessage, string password)
        {





            TripleDESCryptoServiceProvider des = new TripleDESCryptoServiceProvider();
            des.IV = new byte[8];
            PasswordDeriveBytes pdb = new PasswordDeriveBytes(password, new byte[0]);
            des.Key = pdb.CryptDeriveKey(RC2, MD5, 128, new byte[8]);
            MemoryStream ms = new MemoryStream(plainMessage.Length  2);
            CryptoStream encStream = new CryptoStream(ms, des.CreateEncryptor(),
                CryptoStreamMode.Write);
            byte[] plainBytes = Encoding.UTF8.GetBytes(plainMessage);
            encStream.Write(plainBytes, 0, plainBytes.Length);
            encStream.FlushFinalBlock();
            byte[] encryptedBytes = new byte[ms.Length];
            ms.Position = 0;
            ms.Read(encryptedBytes, 0, (int)ms.Length);
            encStream.Close();
            return Convert.ToBase64String(encryptedBytes);
        }
        public static string Decrypt(string hash, string pass)
        {


            TripleDESCryptoServiceProvider decry = new TripleDESCryptoServiceProvider();
            decry.IV = new byte[8];
            PasswordDeriveBytes pdecry = new PasswordDeriveBytes(pass, new byte[0]);
            decry.Key = pdecry.CryptDeriveKey(RC2, MD5, 128, new byte[8]);
            byte[] decrypedbytes = Convert.FromBase64String(hash);
            MemoryStream ds = new MemoryStream(hash.Length);
            CryptoStream decStream = new CryptoStream(ds, decry.CreateDecryptor(),
                CryptoStreamMode.Write);
            decStream.Write(decrypedbytes, 0, decrypedbytes.Length);
            decStream.FlushFinalBlock();
            byte[] decryptedBytes = new byte[ds.Length];
            ds.Position = 0;
            ds.Read(decryptedBytes, 0, (int)ds.Length);
            decStream.Close();

            return Encoding.UTF8.GetString(decryptedBytes);
        }
    }
}
