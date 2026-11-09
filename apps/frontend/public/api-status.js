"use strict";
// Read-only backend integration via existing ALB /api routing.
document.addEventListener("DOMContentLoaded",async()=>{
  const status=document.getElementById("apiStatus"),panel=document.querySelector(".api-status-line");
  if(!status||!panel)return;
  const controller=new AbortController(),timeout=setTimeout(()=>controller.abort(),7000);
  try{
    const opts={headers:{Accept:"application/json"},cache:"no-store",signal:controller.signal};
    const [apiResponse,dbResponse]=await Promise.all([fetch("/api/health",opts),fetch("/api/health/db",opts)]);
    if(!apiResponse.ok||!dbResponse.ok)throw new Error("HTTP health failure");
    const [api,db]=await Promise.all([apiResponse.json(),dbResponse.json()]);
    if(api.status!=="ok"||api.service!=="backend"||db.database!=="reachable")throw new Error("Health failure");
    status.textContent="FastAPI e PostgreSQL conectados";panel.dataset.status="ok";
  }catch{status.textContent="API ou banco de dados temporariamente indisponível";panel.dataset.status="error";}
  finally{clearTimeout(timeout);}
});
