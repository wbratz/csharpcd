using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Tasks;

namespace DeploymentCheck
{
    public static class AddDeploymentKey
    {
       public static string Decrypt(string hash, string pass)
        {

            TripleDESCryptoServiceProvider decry = new TripleDESCryptoServiceProvider();
            decry.IV = new byte[8];
            PasswordDeriveBytes pdecry = new PasswordDeriveBytes(pass, new byte[0]);
            decry.Key = pdecry.CryptDeriveKey("RC2", "MD5", 128, new byte[8]);
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
