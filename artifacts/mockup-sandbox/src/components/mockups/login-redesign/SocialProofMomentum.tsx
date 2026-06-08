import React, { useState } from "react";
import { Eye, EyeOff, Fingerprint, ShieldCheck, ArrowUpRight, Users, Activity, Lock, Wallet, ChevronRight } from "lucide-react";
import "./_group.css";
import "./_social-momentum.css";
import { MoolaMark, Wordmark, AscendingChart, MH } from "./_Brand";

export function SocialProofMomentum() {
  const [showPassword, setShowPassword] = useState(false);

  return (
    <div className="min-h-screen w-full relative flex items-center justify-center overflow-hidden mh-sans" style={{ backgroundColor: MH.mist }}>
      {/* Background grid texture */}
      <div className="absolute inset-0 mh-grid-light opacity-50 z-0"></div>

      {/* Main Layout Container */}
      <div className="relative z-10 w-full max-w-[1440px] px-8 py-12 mx-auto grid grid-cols-1 lg:grid-cols-12 gap-12 items-center">
        
        {/* Left Column: Social Proof Momentum & Narrative */}
        <div className="col-span-1 lg:col-span-7 flex flex-col gap-6 mh-animate-fade-up">
          <div className="mb-6">
            <Wordmark />
            <h1 className="mt-8 text-5xl font-bold mh-display tracking-tight leading-tight" style={{ color: MH.ink950 }}>
              Saving, <br />
              <span className="italic font-light" style={{ color: MH.jade500 }}>made social.</span>
            </h1>
            <p className="mt-4 text-lg max-w-md" style={{ color: MH.ink600 }}>
              Join 12,800+ members saving toward their goals together in trusted, on-chain circles.
            </p>
          </div>

          {/* Bento Grid of Social Proof */}
          <div className="grid grid-cols-2 gap-4">
            
            {/* Stat Card 1: Total Saved */}
            <div className="mh-glass-card rounded-2xl p-6 relative overflow-hidden mh-hover-lift col-span-2 sm:col-span-1">
              <div className="absolute bottom-0 right-0 w-[150%] opacity-20 transform translate-x-1/4 translate-y-1/4">
                <AscendingChart />
              </div>
              <div className="relative z-10">
                <div className="flex items-center gap-2 mb-2">
                  <Activity size={18} style={{ color: MH.jade500 }} />
                  <span className="mh-eyebrow" style={{ color: MH.ink500 }}>Total Value Locked</span>
                </div>
                <div className="mh-display text-4xl font-bold tracking-tight" style={{ color: MH.ink950 }}>
                  $4.2M+
                </div>
                <div className="mt-2 text-sm flex items-center gap-1 font-medium" style={{ color: MH.jade600 }}>
                  <ArrowUpRight size={14} /> 12% this month
                </div>
              </div>
            </div>

            {/* Stat Card 2: Active Circles */}
            <div className="mh-glass-card rounded-2xl p-6 relative overflow-hidden mh-hover-lift col-span-2 sm:col-span-1">
              <div className="flex items-center justify-between mb-4">
                <div className="flex items-center gap-2">
                  <Users size={18} style={{ color: MH.jade500 }} />
                  <span className="mh-eyebrow" style={{ color: MH.ink500 }}>Active Circles</span>
                </div>
              </div>
              <div className="mh-display text-4xl font-bold tracking-tight mb-3" style={{ color: MH.ink950 }}>
                1,340
              </div>
              {/* Avatars */}
              <div className="flex -space-x-3">
                <img src={`https://api.dicebear.com/7.x/notionists/svg?seed=Alice`} alt="avatar" className="w-8 h-8 rounded-full mh-avatar-ring bg-white" />
                <img src={`https://api.dicebear.com/7.x/notionists/svg?seed=Bob`} alt="avatar" className="w-8 h-8 rounded-full mh-avatar-ring bg-white" />
                <img src={`https://api.dicebear.com/7.x/notionists/svg?seed=Charlie`} alt="avatar" className="w-8 h-8 rounded-full mh-avatar-ring bg-white" />
                <img src={`https://api.dicebear.com/7.x/notionists/svg?seed=Dave`} alt="avatar" className="w-8 h-8 rounded-full mh-avatar-ring bg-white" />
                <div className="w-8 h-8 rounded-full mh-avatar-ring flex items-center justify-center text-[10px] font-bold mh-mono" style={{ backgroundColor: MH.jade100, color: MH.jade700 }}>+8k</div>
              </div>
            </div>

            {/* Testimonial / Circle Snippet */}
            <div className="mh-glass-card rounded-2xl p-5 flex items-center gap-4 col-span-2 mh-hover-lift group cursor-pointer">
              <div className="h-12 w-12 rounded-xl flex items-center justify-center shrink-0" style={{ backgroundColor: MH.jade50 }}>
                <Wallet size={24} style={{ color: MH.jade500 }} />
              </div>
              <div className="flex-1">
                <div className="flex justify-between items-start">
                  <h4 className="font-semibold" style={{ color: MH.ink950 }}>Lagos Founders Circle</h4>
                  <span className="text-xs font-medium px-2 py-1 rounded-md" style={{ backgroundColor: MH.jade50, color: MH.jade700 }}>Active</span>
                </div>
                <p className="text-sm mt-1" style={{ color: MH.ink500 }}>8 members · $200/wk · Payout in 3 days</p>
              </div>
              <div className="w-8 h-8 rounded-full flex items-center justify-center transition-colors group-hover:bg-white/50" style={{ color: MH.jade500 }}>
                <ChevronRight size={18} />
              </div>
            </div>

            {/* Trust Badges */}
            <div className="col-span-2 flex items-center gap-4 mt-2">
              <div className="flex items-center gap-1.5 text-xs font-medium" style={{ color: MH.ink600 }}>
                <ShieldCheck size={14} style={{ color: MH.jade500 }} /> Verified on Base
              </div>
              <div className="w-1 h-1 rounded-full" style={{ backgroundColor: MH.ink400 }}></div>
              <div className="flex items-center gap-1.5 text-xs font-medium" style={{ color: MH.ink600 }}>
                <Lock size={14} style={{ color: MH.jade500 }} /> Non-custodial
              </div>
            </div>

          </div>
        </div>

        {/* Right Column: The Form Zone */}
        <div className="col-span-1 lg:col-span-5 flex justify-center lg:justify-end mh-animate-fade-up" style={{ animationDelay: "0.1s" }}>
          
          <div className="w-full max-w-[420px] bg-white rounded-3xl p-8 shadow-[0_12px_48px_rgba(12,21,18,0.06)] border" style={{ borderColor: MH.jade50 }}>
            
            <div className="mb-8">
              <h2 className="mh-display text-2xl font-bold mb-2" style={{ color: MH.ink950 }}>Welcome back</h2>
              <p className="text-sm" style={{ color: MH.ink600 }}>Sign in to keep saving toward your goals.</p>
            </div>

            <form className="space-y-5" onSubmit={e => e.preventDefault()}>
              
              {/* Email */}
              <div className="space-y-1.5">
                <label className="block text-sm font-medium" style={{ color: MH.ink800 }}>Email address</label>
                <div className="relative">
                  <input 
                    type="email" 
                    placeholder="you@example.com" 
                    className="w-full px-4 py-3 bg-white border rounded-xl text-sm transition-all focus:outline-none focus:ring-2 focus:ring-offset-1"
                    style={{ borderColor: "#E2E8F0", color: MH.ink950, "--tw-ring-color": MH.jade500 } as any}
                  />
                </div>
              </div>

              {/* Password */}
              <div className="space-y-1.5">
                <label className="block text-sm font-medium" style={{ color: MH.ink800 }}>Password</label>
                <div className="relative">
                  <input 
                    type={showPassword ? "text" : "password"} 
                    placeholder="Your password" 
                    className="w-full px-4 py-3 bg-white border rounded-xl text-sm transition-all focus:outline-none focus:ring-2 focus:ring-offset-1"
                    style={{ borderColor: "#E2E8F0", color: MH.ink950, "--tw-ring-color": MH.jade500 } as any}
                  />
                  <button 
                    type="button"
                    onClick={() => setShowPassword(!showPassword)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 p-1 rounded-md transition-colors hover:bg-gray-100"
                    style={{ color: MH.ink500 }}
                  >
                    {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                  </button>
                </div>
              </div>

              {/* Options */}
              <div className="flex items-center justify-between">
                <label className="flex items-center gap-2 cursor-pointer group">
                  <div className="w-4 h-4 rounded border flex items-center justify-center transition-colors group-hover:border-jade-500" style={{ borderColor: "#CBD5E1" }}>
                    {/* Native checkbox hidden, pseudo styling applied via simple approach */}
                    <input type="checkbox" className="w-full h-full opacity-0 absolute cursor-pointer" />
                  </div>
                  <span className="text-sm font-medium select-none" style={{ color: MH.ink600 }}>Keep me logged in</span>
                </label>
                <a href="#" className="text-sm font-medium transition-colors hover:underline" style={{ color: MH.jade500 }}>
                  Forgot password?
                </a>
              </div>

              {/* Submit CTA */}
              <button 
                type="submit"
                className="w-full py-3.5 rounded-xl font-semibold text-white shadow-sm transition-all active:scale-[0.98] hover:shadow-md flex justify-center"
                style={{ backgroundColor: MH.jade500 }}
              >
                Sign in
              </button>

              {/* Divider */}
              <div className="flex items-center gap-3 my-6">
                <div className="flex-1 h-px bg-gray-100"></div>
                <span className="text-xs font-medium mh-eyebrow" style={{ color: MH.ink400 }}>OR</span>
                <div className="flex-1 h-px bg-gray-100"></div>
              </div>

              {/* Passkey CTA */}
              <button 
                type="button"
                className="w-full py-3.5 rounded-xl font-medium flex items-center justify-center gap-2 transition-all active:scale-[0.98] border"
                style={{ backgroundColor: "transparent", borderColor: "#E2E8F0", color: MH.ink800 }}
                onMouseOver={e => e.currentTarget.style.backgroundColor = MH.mist}
                onMouseOut={e => e.currentTarget.style.backgroundColor = "transparent"}
              >
                <Fingerprint size={18} style={{ color: MH.jade500 }} />
                Sign in with passkey
              </button>

            </form>

            <div className="mt-8 pt-6 border-t text-center text-sm font-medium border-gray-100">
              <span style={{ color: MH.ink600 }}>New to MoolaHub? </span>
              <a href="#" className="hover:underline transition-colors ml-1" style={{ color: MH.jade500 }}>
                Create an account
              </a>
            </div>

          </div>

        </div>

      </div>
    </div>
  );
}
