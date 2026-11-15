package app.companion.messenger;

import android.app.Activity;
import android.content.*;
import android.graphics.Color;
import android.net.Uri;
import android.os.*;
import android.webkit.*;
import android.widget.FrameLayout;
import android.view.*;
import java.io.*;
import java.util.*;

/** A client-only Android app. Bundled assets are intercepted in-process, not served over a port. */
public final class MainActivity extends Activity {
 private static final String HOST="appassets.androidplatform.net";
 private static final int PICK_IMAGE=81,RECORD_PERMISSION=82;
 private PermissionRequest pendingAudio;
 private WebView web;
 private ValueCallback<Uri[]> pendingFile;
 @Override public void onCreate(Bundle state){
  super.onCreate(state);
  getWindow().setStatusBarColor(Color.BLACK);getWindow().setNavigationBarColor(Color.BLACK);
  FrameLayout root=new FrameLayout(this);root.setBackgroundColor(Color.BLACK);
  if(Build.VERSION.SDK_INT>=30){root.setOnApplyWindowInsetsListener((v,insets)->{android.graphics.Insets bars=insets.getInsets(WindowInsets.Type.systemBars());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);return insets;});}
  web=new WebView(this);web.setBackgroundColor(Color.BLACK);root.addView(web,new FrameLayout.LayoutParams(-1,-1));setContentView(root);
  WebSettings settings=web.getSettings();settings.setJavaScriptEnabled(true);settings.setDomStorageEnabled(true);settings.setAllowFileAccess(false);settings.setAllowContentAccess(true);settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);settings.setJavaScriptCanOpenWindowsAutomatically(false);settings.setSupportMultipleWindows(false);settings.setMediaPlaybackRequiresUserGesture(true);settings.setUserAgentString(settings.getUserAgentString()+" CompanionAndroid/0.6.0");
  CookieManager.getInstance().setAcceptThirdPartyCookies(web,false);
  web.addJavascriptInterface(new NativeUI(),"CompanionAndroid");
  web.setWebViewClient(new WebViewClient(){
   @Override public WebResourceResponse shouldInterceptRequest(WebView view,WebResourceRequest request){
    Uri uri=request.getUrl();if(!HOST.equals(uri.getHost()))return null;
    if(!"https".equals(uri.getScheme()))return missing();
    String path=uri.getPath();if(path==null||path.equals("/"))path="/index.html";
    if(path.contains("..")||path.contains("\\")||!"GET".equals(request.getMethod()))return missing();
    try {String name=path.substring(1);String mime=type(name);return new WebResourceResponse(mime,mime.startsWith("text/")||mime.contains("javascript")||mime.contains("json")?"UTF-8":null,200,"OK",Collections.singletonMap("Cache-Control","no-cache"),getAssets().open("web/"+name));}catch(IOException e){return missing();}
   }
   @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request){
    Uri uri=request.getUrl();if("https".equals(uri.getScheme())&&HOST.equals(uri.getHost()))return false;
    if(request.hasGesture()&&"https".equals(uri.getScheme()))try{startActivity(new Intent(Intent.ACTION_VIEW,uri));}catch(ActivityNotFoundException ignored){}
    return true;
   }
  });
  web.setWebChromeClient(new WebChromeClient(){
   @Override public boolean onShowFileChooser(WebView view,ValueCallback<Uri[]> callback,FileChooserParams params){
    if(pendingFile!=null)pendingFile.onReceiveValue(null);pendingFile=callback;
    Intent pick=new Intent(Intent.ACTION_OPEN_DOCUMENT);pick.setType("*/*");pick.addCategory(Intent.CATEGORY_OPENABLE);
    boolean videos=false;for(String accept:params.getAcceptTypes())if(accept.contains("video"))videos=true;
    pick.putExtra(Intent.EXTRA_MIME_TYPES,videos?new String[]{"image/png","image/jpeg","image/webp","video/mp4","video/webm"}:new String[]{"image/png","image/jpeg","image/webp"});
    pick.putExtra(Intent.EXTRA_ALLOW_MULTIPLE,params.getMode()==FileChooserParams.MODE_OPEN_MULTIPLE);
    try{startActivityForResult(pick,PICK_IMAGE);}catch(ActivityNotFoundException e){pendingFile.onReceiveValue(null);pendingFile=null;}return true;
   }
   @Override public void onPermissionRequest(PermissionRequest request){runOnUiThread(()->{
    if(!HOST.equals(request.getOrigin().getHost())||!"https".equals(request.getOrigin().getScheme())){request.deny();return;}
    String[] resources=request.getResources();if(resources.length!=1||!PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(resources[0])){request.deny();return;}
    if(checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)==android.content.pm.PackageManager.PERMISSION_GRANTED){request.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});return;}
    if(pendingAudio!=null)pendingAudio.deny();pendingAudio=request;requestPermissions(new String[]{android.Manifest.permission.RECORD_AUDIO},RECORD_PERMISSION);
   });}
   @Override public void onPermissionRequestCanceled(PermissionRequest request){if(pendingAudio==request)pendingAudio=null;}
  });
  web.loadUrl("https://"+HOST+"/index.html");
 }
 private static WebResourceResponse missing(){return new WebResourceResponse("text/plain","UTF-8",404,"Not Found",Collections.emptyMap(),new ByteArrayInputStream("Not found".getBytes()));}
 private static String type(String name){if(name.endsWith(".js"))return "application/javascript";if(name.endsWith(".css"))return "text/css";if(name.endsWith(".html"))return "text/html";if(name.endsWith(".json")||name.endsWith(".webmanifest"))return "application/json";if(name.endsWith(".svg"))return "image/svg+xml";if(name.endsWith(".png"))return "image/png";if(name.endsWith(".webp"))return "image/webp";if(name.endsWith(".ttf"))return "font/ttf";return "application/octet-stream";}
 public final class NativeUI {
  @JavascriptInterface public void copy(String text){runOnUiThread(()->{ClipboardManager manager=(ClipboardManager)getSystemService(CLIPBOARD_SERVICE);manager.setPrimaryClip(ClipData.newPlainText("Companion",text));});}
 }
 @Override protected void onActivityResult(int request,int result,Intent data){super.onActivityResult(request,result,data);if(request==PICK_IMAGE&&pendingFile!=null){ArrayList<Uri> uris=new ArrayList<>();if(result==RESULT_OK&&data!=null){if(data.getClipData()!=null){for(int i=0;i<data.getClipData().getItemCount();i++){Uri uri=data.getClipData().getItemAt(i).getUri();if("content".equals(uri.getScheme()))uris.add(uri);}}else if(data.getData()!=null&&"content".equals(data.getData().getScheme()))uris.add(data.getData());}pendingFile.onReceiveValue(uris.isEmpty()?null:uris.toArray(new Uri[0]));pendingFile=null;}}
 @Override public void onRequestPermissionsResult(int request,String[] permissions,int[] grants){super.onRequestPermissionsResult(request,permissions,grants);if(request==RECORD_PERMISSION&&pendingAudio!=null){if(grants.length>0&&grants[0]==android.content.pm.PackageManager.PERMISSION_GRANTED)pendingAudio.grant(new String[]{PermissionRequest.RESOURCE_AUDIO_CAPTURE});else pendingAudio.deny();pendingAudio=null;}}
 @Override public void onBackPressed(){web.evaluateJavascript("(()=>{const d=document.querySelector('dialog[open]');if(d){d.close();return true;}if(document.body.classList.contains('mobile-chat')){document.body.classList.remove('mobile-chat');return true;}return false;})()",result->{if(!"true".equals(result))finish();});}
 @Override protected void onPause(){super.onPause();if(web!=null){if(pendingAudio==null)web.evaluateJavascript("window.CompanionStopRecording&&window.CompanionStopRecording()",null);web.onPause();}}
 @Override protected void onStop(){if(web!=null)web.evaluateJavascript("window.CompanionStopRecording&&window.CompanionStopRecording()",null);super.onStop();}
 @Override protected void onResume(){super.onResume();if(web!=null)web.onResume();}
 @Override protected void onDestroy(){if(pendingFile!=null){pendingFile.onReceiveValue(null);pendingFile=null;}if(pendingAudio!=null){pendingAudio.deny();pendingAudio=null;}if(web!=null){web.removeJavascriptInterface("CompanionAndroid");web.destroy();}super.onDestroy();}
}
