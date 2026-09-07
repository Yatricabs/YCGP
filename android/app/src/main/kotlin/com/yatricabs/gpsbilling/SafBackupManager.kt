package com.yatricabs.gpsbilling

import android.content.Context
import android.content.SharedPreferences
import android.net.Uri
import androidx.documentfile.provider.DocumentFile

object SafBackupManager {
    private const val PREFS = "yatri_saf_backup"
    private const val KEY_FOLDER_URI = "backup_folder_uri"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun savedFolderUri(context: Context): Uri? =
        prefs(context).getString(KEY_FOLDER_URI, null)?.let { raw ->
            try {
                Uri.parse(raw)
            } catch (_: Exception) {
                null
            }
        }

    fun persistFolderUri(context: Context, uri: Uri) {
        prefs(context).edit().putString(KEY_FOLDER_URI, uri.toString()).apply()
    }

    fun hasUsableBackupFolder(context: Context): Boolean {
        val uri = savedFolderUri(context) ?: return false
        val granted = context.contentResolver.persistedUriPermissions.any {
            it.uri == uri && it.isReadPermission && it.isWritePermission
        }
        if (!granted) return false
        return try {
            DocumentFile.fromTreeUri(context, uri)?.exists() == true
        } catch (_: Exception) {
            false
        }
    }

    fun writeFile(context: Context, fileName: String, content: String): Boolean {
        val treeUri = savedFolderUri(context) ?: return false
        return try {
            val tree = DocumentFile.fromTreeUri(context, treeUri) ?: return false
            val target = tree.findFile(fileName) ?: tree.createFile("application/json", fileName)
                ?: return false
            context.contentResolver.openOutputStream(target.uri, "wt")?.use {
                it.write(content.toByteArray(Charsets.UTF_8))
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    fun readFile(context: Context, fileName: String): String? {
        val treeUri = savedFolderUri(context) ?: return null
        return try {
            val tree = DocumentFile.fromTreeUri(context, treeUri) ?: return null
            val target = tree.findFile(fileName) ?: return null
            context.contentResolver.openInputStream(target.uri)?.use {
                it.bufferedReader(Charsets.UTF_8).readText()
            }
        } catch (_: Exception) {
            null
        }
    }
}
